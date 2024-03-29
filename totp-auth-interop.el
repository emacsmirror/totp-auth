;;; totp-auth-interop.el --- Import secrets -*- mode: emacs-lisp; lexical-binding: t; -*-
;; Copyright © 2022-2024 Vivek Das Mohapatra <vivek@etla.org>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Allows easy import of RFC6238 secrets from text files, otpauth
;; and otpauth-migration URLs, and standard OTP QR code images.

;;; Code:
(eval-and-compile
  (let ((load-path load-path)
        (this-file (or load-file-name
                       byte-compile-current-file
                       buffer-file-name)))
    (when (not (and (locate-library "base32")
                    (locate-library "hmac")))
      (add-to-list 'load-path (file-name-directory this-file)))
    (require 'totp-auth)
    (require 'epa-hook))
  ;; function declared obsolete in 29.x
  ;; do not use #' forms here as that will trigger a different warning
  (if (fboundp 'image-supported-file-p)
      (defalias 'totp-auth-image-type-from-filename
        'image-supported-file-p)
    (defalias 'totp-auth-image-type-from-filename
      'image-type-from-file-name))
  (require 'mailcap))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; This file implements import/export functionality for common OTP exchange
;; formats like otpauth URLs and QR encoded OTP secrets

;; It isn't necessary for usual day-to-day totp.el use, only when
;; You need to get your TOTP secrets into or out of the totp.el system.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; partial protobuffer support so we can decode otpauth-migration URLs
(defconst totp-auth-pb-types [:varint :i64 :len :start :end :i32])

(defun totp-auth-pb-type (n)
  "Look up the protobuffer type by its serialisation numeric code N."
  (when (< n (length totp-auth-pb-types))
    (aref totp-auth-pb-types n)))

(defun totp-auth-pb-read-varint (bytes &optional pos)
  "Read a varint from a protobuffer array, vector or string BYTES at offset POS.
Returns a cons of (VALUE . BYTES-READ)"
  (let ((u64 0)
        b10 byte collected vbyte-count)
    (or pos (setq pos 0))
    ;; VARINTs are 0-9 bytes with the high bit set
    ;; followed 1 byte with the high bit unset
    (while (eq #x80 (logand #x80 (setq byte (aref bytes pos))))
      (setq collected (cons (logand #x7f byte) collected)
            pos       (1+ pos)))
    (setq collected   (nreverse (cons byte collected))
          collected   (concat collected)
          vbyte-count (length collected))
    ;; VARINTs can threfore be no more than 10 bytes of encoded data
    (if (> vbyte-count 10)
        (cons nil vbyte-count);; varint overflow
      (when (= vbyte-count 10)
        ;; If there are 10 bytes then the first byte must be 0x1
        ;; as 9 varint encoding bytes gives 9×7 = 63 bits, which
        ;; only leaves 1 bit.
        (setq b10 (aref collected 9)))
      (dotimes (i (length collected))
        (setq u64 (+ u64 (base32-lsh (aref collected i) (* i 7)))))
      (if (and b10 (not (eq b10 1)))
          (cons nil vbyte-count)
        (cons u64 vbyte-count))) ))

(defun totp-auth-pb-read-tag (buf &optional pos)
  "Read a protobuffer tag, which is (field-number << 3 | type).
Reads from an array, vector or string BUF at offset POS.
Returns a structure: ((FIELD . TYPE) . BYTES-READ)
Where TYPE should be :varint :i64 :len or :i32"
  (let ((decoded (totp-auth-pb-read-varint buf pos)) type field)
    (setq field (car decoded)
          type  (totp-auth-pb-type (logand #x7 field))
          field (base32-lsh field -3))
    (setcar decoded (cons field type))
    decoded))

(defun totp-auth-pb-read-raw (buf len &optional pos)
  "Read LEN bytes from a vector or string BUF at offset POS (default 0).
Returns a unibyte string containing those bytes."
  (let ((raw    (make-string len 0))
        (offset (or pos 0)))
    (dotimes (i len)
      (aset raw i (logand #xff (aref buf (+ i offset)))))
    (encode-coding-string raw 'raw-text)))

(defun totp-auth-pb-read-len (buf &optional pos)
  "Read a variable-length byte string from a string or vector BUF at offset POS."
  (let (pb len bytes offset read)
    (setq offset (or pos 0)
          pb     (totp-auth-pb-read-varint buf offset)
          len    (car pb)
          read   (cdr pb)
          ;;x      (message "--- want %d bytes (ate %d)" len read)
          offset (+ offset read)
          bytes  (totp-auth-pb-read-raw buf len offset))
    (cons bytes (+ read len))))

(defconst totp-auth-pb-otpauth-migration-field-map
  [nil :secret (:service . :user) :service :algo :digits :type nil])

(defun totp-auth-pb-otpauth-migration-translate-field (field val)
  "Translate a FIELD number (1-6) and VAL into cons cell(s).
The cell(s) returned are suitable for use in the return
value of ‘totp-auth-unwrap-otp-blob’."
  (let (key)
    (setq key (and (< 0 field)
                   (> (length totp-auth-pb-otpauth-migration-field-map) field)
                   (aref totp-auth-pb-otpauth-migration-field-map field)))
    (cond ((not key)        nil)
          ((eq key :algo)   nil) ;; not yet handled
          ((eq key :type)   nil) ;; can only be TOTP or HOTP, so unimportant
          ((eq key :digits) (when (numberp val)
                              (setq val (+ (* val 2) 4))
                              (cons :digits (if (memq val '(6 8)) val 6))))
          ;; field #2 is either a "service:user" string or just a "service" one
          ;; we have to inspect the contents and guess.
          ((consp key)      (if (and (stringp val)
                                     (string-match "^\\(.+\\)?:\\(.+\\)" val))
                                (list (cons (car key) (match-string 1 val))
                                      (cons (cdr key) (match-string 2 val)))
                              (cons (car key) val)))
          ((eq key :secret) (if (stringp val) (cons :secret (base32-encode val))))
          (t                (cons key val))) ))

(defun totp-auth-pb-decode-migration-item (buf)
  "Unpack a secret and metadata from an otpauth-migration URL fragment BUF."
  (let ((offset 0)
        (what :tag)
        res pb-item pb-value pb-field slot)
    (while (< offset (length buf))
      (setq pb-item  (cond
                      ((eq what :tag)    (totp-auth-pb-read-tag buf offset))
                      ((eq what :len)    (totp-auth-pb-read-len buf offset))
                      ((eq what :varint) (totp-auth-pb-read-varint buf offset))
                      (t (error "Unhandled type: %S" what)))
            pb-value (car pb-item)
            offset   (+ (cdr pb-item) offset))
      ;; next     (if (eq what :tag) (cdr pb-value) :tag))
      (if (eq what :tag)
          (setq what (cdr pb-value) pb-field (car pb-value))
        (setq slot (totp-auth-pb-otpauth-migration-translate-field pb-field pb-value)
              what :tag)
        (when slot
          (if (consp (cdr slot))
              (setq res (cons (car slot)
                              (cons (cadr slot)
                                    res)))
            (setq res (cons slot res)))) ))
    ;;(with-current-buffer (get-buffer-create "*migrate*")
    ;;  (insert (pp res) "\n---\n"))
    res))

(defun totp-auth-pb-decode-migration-data (buf &optional pos)
  "Decode the payload of an otpauth-migration url in BUF at offset POS."
  (let (offset pb-item pb-value what next result item i)
    (setq offset (or pos 0)
          i      0
          what   :tag)
    (while (< offset (length buf))
      (setq pb-item  (cond
                      ((eq what :tag)    (totp-auth-pb-read-tag buf offset))
                      ((eq what :len)    (totp-auth-pb-read-len buf offset))
                      ((eq what :varint) (totp-auth-pb-read-varint buf offset))
                      (t (error "Unhandled type: %S" what)))
            pb-value (car pb-item)
            offset   (+ (cdr pb-item) offset)
            next     (if (eq what :tag) (cdr pb-value) :tag))
      (if (eq what :len)
          (when (setq item (totp-auth-pb-decode-migration-item pb-value))
            (setq result (cons item result))))
      (setq what next i (1+ i)))
    result))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; partial protobuffer write support
(defun totp-auth-pb-encode-varint (u64)
  "Encode an unsigned 64 bit uint U64 as a protobuf varint.
Varints are 1-10 bytes in length, with all but the last byte having
the high bit set."
  ;; a varint is base 128, with the high bit used as a continuation bit
  ;; therefore to encode it we need to know how many 7 bit blocks are
  ;; required to encode the integer in question
  ;; NOTE: ash is safe here as we've forbidden negative inputs
  (when (> 0 u64)
    (error "Cannot varint-encode negative numbers %S" u64))
  (let ((blocks 1) (tmp u64) (varint (list)))
    (while (not (zerop (setq tmp (ash tmp -7))))
      (setq blocks (1+ blocks)))
    (cond ((eq blocks 1 ) (setq varint (format "%c" u64)))
          ((>  blocks 10) (error "Number %S too large for varint" u64))
          (t
           (dotimes (i blocks)
             (setq varint
                   (cons (logior (logand #x7f (ash u64 (* -7 i)))
                                 (if (eq (1- blocks) i) #x00 #x80))
                         varint)))
           (setq varint (mapconcat #'byte-to-string (nreverse varint) ""))))
    (encode-coding-string varint 'raw-text)))

(defun totp-auth-pb-encode-len (bytes)
  "Encode BYTES as a protobuf len type.
A protobuf len which consists of a protobuf varint (giving the length)
followed by a sequence of bytes of that length."
  (let (payload size)
    (setq payload (encode-coding-string bytes 'raw-text)
          size    (string-bytes payload))
    (concat (totp-auth-pb-encode-varint size)
            payload)))

(defun totp-auth-pb-type-int (type)
  "Translate a symbol TYPE (see ‘totp-auth-pb-types’) to its numeric value."
  (let ((i 0) res)
    (while (and (not res) (> (length totp-auth-pb-types) i))
      (if (eq (aref totp-auth-pb-types i) type) (setq res i))
      (setq i (1+ i)))
    res))

(defun totp-auth-pb-encode-tag (field type)
  "Encode a protobuffer tag (FIELD << 3 | TYPE) to a byte.
Type should be a value from ‘totp-auth-pb-types’ translated to
an integer by ‘totp-auth-pb-type-int’."
  (totp-auth-pb-encode-varint
   (logior (ash field 3)
           (logand #x7
                   (if (integerp type)
                       type
                     (totp-auth-pb-type-int type))))))

(defun totp-auth-pb-encode-secret (s)
  "Take a ‘totp-auth-unwrap-otp-blob’ secret S and protobuf encode it.
The return value will be the raw byte sequence encoding that secret."
  (let (encoded issuer)
    (mapc
     (lambda (x &optional val from field as)
       (setq from    (car    x)
             field   (cadr   x)
             as      (caddr  x))
       (setq val (if (consp from)
                     (let ((a (cdr (assq (car from) s)))
                           (b (cdr (assq (cdr from) s))))
                       ;; remember the issuer so we don't repeat it
                       (if (stringp a) (setq issuer a))
                       (if (and (stringp a) (stringp b))
                           (concat a ":" b)
                         (if (stringp a)
                             a
                           (if (stringp b)
                               b
                             nil))))
                   (cdr (assq from s)))
             val (or val (nth 3 x)))
       (if (and (eq :service from) (equal issuer val))
           (setq val nil))
       (when val
         ;; secret should be in raw binary form, not its b32 wrapper
         (if (eq :secret from)
             (setq val (base32-decode (upcase val))))
         (push (totp-auth-pb-encode-tag field as) encoded)
         (push (cond ((eq :varint as) (totp-auth-pb-encode-varint val))
                     ((eq :len    as) (totp-auth-pb-encode-len    val))
                     (t (error "Unhandled encode type %S" as)))
               encoded)))
   '((:secret            1 :len)
     ((:service . :user) 2 :len)
     (:service           3 :len)
     (:algo              4 :varint)
     (:digits            5 :varint 6)
     (:type              6 :varint 2)))
    (mapconcat 'identity (nreverse encoded) "")))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun totp-auth-unwrap-otpauth-migration-url (u)
  "Unpack an otpauth-migration url U and extract the parts we care about.
Similar to ‘totp-auth-unwrap-otpauth-url’ except:
 - for otpauth-migration:// URLs
 - returns a list of 0 or more secret srtuctures instead of just one."
  (let (query data)
    (setq u     (url-path-and-query u)
          query (cdr u)
          query (url-parse-query-string query)
          data  (cadr (assoc "data" query))
          data  (base64-decode-string data))
    (totp-auth-pb-decode-migration-data data)))

(defun totp-auth-parse-buffer-otp-urls (&optional buffer)
  "Search for otpauth and otpauth-migration URLs in BUFFER.
BUFFER defaults to the current buffer.
Returns a list of all the OTP secrets+metadata by calling
‘totp-auth-unwrap-otp-blob’ on them."
  (let (result url-string url)
    (with-current-buffer (or buffer (current-buffer))
      (goto-char (point-min))
      (while (re-search-forward "\\(otpauth\\(?:-migration\\)?://.*\\)$" nil t)
        (setq url-string (match-string 1))
        (if (string-prefix-p "otpauth-migration://" url-string)
            (when (setq url (url-generic-parse-url url-string))
              (setq result
                    (append result
                            (totp-auth-unwrap-otpauth-migration-url url))))
          (setq result
                (cons (totp-auth-unwrap-otp-blob url-string) result)))))
    result))

(defun totp-auth-check-command (cmd-list)
  "Return the full path to the execuyable specified in CMD-LIST.
Returns nil if no command is found."
  (let ((target (if (listp cmd-list) (car cmd-list) cmd-list)))
    (and target (stringp target) (executable-find target))))

(defun totp-auth-load-image-file (file)
  "Use ‘totp-auth-file-import-command’ to extract the contents of FILE.
The contents are passed to ’totp-auth-parse-buffer-otp-urls’."
  (unless (totp-auth-check-command totp-auth-file-import-command)
    (error "Command %s not available for QR code import"
           (car totp-auth-file-import-command)))
  (let ((args (mapcar (lambda (a) (if (equal "@file@" a) file a))
                      (cdr totp-auth-file-import-command))))
    (with-temp-buffer
      (apply #'call-process (car totp-auth-file-import-command) nil t nil args)
      (totp-auth-parse-buffer-otp-urls)) ))

(defun totp-auth-find-hmac-key-by-class (class len)
  "Search for an HMAC key based on the regex character class CLASS.
The expected length of the key is LEN."
  (let ((pattern (format "\\b%s\\{%d\\}\\b" class len)))
    (and (re-search-forward pattern nil t) (match-string 0))))

(defun totp-auth-find-hmac-key ()
  "Find one of the common base32 encoded TOTP HMAC keys."
  (let ((b32-class (concat "[" base32-dictionary "]")))
    (or (totp-auth-find-hmac-key-by-class b32-class 20)
        (totp-auth-find-hmac-key-by-class b32-class 32)
        (totp-auth-find-hmac-key-by-class b32-class 64))))

(defun totp-auth-load-file (file)
  "Load secret(s) from FILE.
FILE may be:
  - a single base32 encoded TOTP secret
  - any number of otpauth:// scheme URLs
  - any number of otpauth-migration:// scheme URLs
  - a mix of entries encoded in the above URL schemes
  - a QR code understood by ‘totp-file-import-command’.\n
Returns a list of TOTP secret alists - that is: Each element of
the returned list is a structure returned by ‘totp-auth-unwrap-otp-blob’."
  (let (mime-type result)
    (setq file      (expand-file-name file)
          mime-type (mailcap-extension-to-mime (file-name-extension file)))
    (if (string-match "^image/" (or mime-type ""))
        (totp-auth-load-image-file file)
      (with-temp-buffer
        (when (ignore-errors (insert-file-contents file))
          (goto-char (point-min))
          (or (totp-auth-parse-buffer-otp-urls)
              (and (goto-char (point-min))
                   (setq result (totp-auth-find-hmac-key))
                   (list (totp-auth-unwrap-otp-blob result)))) )) )))

(defun totp-auth-b64-len (n)
  "Return the number of bytes required to base64 encode N bytes."
  (let (rem pad)
    (setq rem (% n 3)
          pad (if (zerop rem) 0 (- 3 rem)))
    (* (/ (+ n pad) 3) 4)))

(defun totp-auth-make-export-suffix (size nth id)
  "Make an otpauth-migration URL protobuf suffix.
SIZE is the number or otpauth URLs in this URL.
NTH is the index (0 based) of this URL in the current export batch.
ID is the unique-ish id of this export batch."
  (concat ;;version
          (totp-auth-pb-encode-tag 2 :varint)
          (totp-auth-pb-encode-varint 1)
          ;;batch size
          (totp-auth-pb-encode-tag 3 :varint)
          (totp-auth-pb-encode-varint size)
          ;;nth chunk
          (totp-auth-pb-encode-tag 4 :varint)
          (totp-auth-pb-encode-varint nth)
          ;; batch uid
          (totp-auth-pb-encode-tag 5 :varint)
          (totp-auth-pb-encode-varint id)))

(defun totp-auth-url-length (stub-len &rest data-len)
  "Calculate the length of an ASCII stub followed by base64 encoded blobs.
STUB-LEN is the length of the ASCII-safe part of the URL.
DATA-LEN is the byte lengths of all the binary blobs which will be
concatenated and base64 encoded."
  (+ stub-len (totp-auth-b64-len (apply #'+ data-len))))

(defun totp-auth-wrap-otpauth-migration-url (secrets &optional chunk)
  "Wrap list SECRETS in otpauth-migration URLs.
The TOTP secrets structure is described by ‘totp-auth-unwrap-otp-blob’.
URLs will not exceed CHUNK in length.
CHUNK defaults to ‘totp-auth-export-url-max-size’.
Returns a list of otpauth-migration:// URLs."
  (let ((limit    (or chunk totp-auth-export-url-max-size))
        (stub     "otpauth-migration://offline?data=")
        (batch-id (+ (* (floor (time-to-seconds) 1000))
                     (random 1000)))
        ;; -len is used for things that are ok as ascii
        ;; -bytes is used for things that need to be base64 encoded
        (enc-data       nil)
        (chunk-data      "")
        (chunk-data-bytes 0)
        (chunk-count      0)
        (secret-count     0)
        next-data-bytes
        blob-data-bytes
        stub-len
        suffix
        suffix-bytes
        url-data
        urls)
    ;; the suffix is actually a placeholder but as the fields that
    ;; can vary will never exceed 1 byte in the pb encoding we can use
    ;; this initial value in our size calculations:
    (setq suffix       (totp-auth-make-export-suffix 1 0 batch-id)
          suffix-bytes (string-bytes suffix)
          stub-len     (string-bytes stub)
          url-data     (mapcar (lambda (x)
                                 (concat (totp-auth-pb-encode-tag 1 :len )
                                         (totp-auth-pb-encode-len x)))
                               (mapcar #'totp-auth-pb-encode-secret secrets)))
    (dolist (secret-data url-data)
      (setq chunk-data-bytes (string-bytes chunk-data)
            next-data-bytes  (string-bytes secret-data)
            blob-data-bytes  (+ chunk-data-bytes next-data-bytes suffix-bytes))
      (if (<= (totp-auth-url-length stub-len blob-data-bytes) limit)
          (setq chunk-data   (concat chunk-data secret-data)
                secret-count (1+ secret-count))
        (setq enc-data      (cons chunk-data enc-data)
              secret-count  0
              chunk-count   (1+ chunk-count)
              chunk-data    "")
        (if (<= (totp-auth-url-length stub-len next-data-bytes suffix-bytes)
                limit)
            (setq chunk-data   secret-data
                  secret-count 1)
          (error "Secret %d in chunk %d will not fit in chunk size %d"
                 secret-count chunk-count limit)) ))
    (if (and (stringp chunk-data) (not (zerop (string-bytes chunk-data))))
        (setq enc-data      (cons chunk-data enc-data)
              chunk-count   (length enc-data)))
    (dotimes (i chunk-count)
      (setq chunk-data (nth (- chunk-count i 1) enc-data)
            suffix     (totp-auth-make-export-suffix i chunk-count batch-id)
            urls       (cons (concat stub
                                     (base64-encode-string
                                      (concat chunk-data suffix) t))
                             urls)))
    (nreverse urls)))

(defun totp-auth-nthify-file-name (file nth)
  "Transform a filaneme FILE to be an NTH numbered version.
FILE is the original filename.
NTH is positive integer.
eg “foo.png” → “foo.01.png”"
  (save-match-data
    (if (string-match "\\(\\.[^.+]+\\'\\)" file)
        (replace-match (format ".%02d\\1" (abs nth)) nil nil file)
      (format "%s.%02d.otp" file (abs nth)))))

(defun totp-auth-file-export-type-arg (img-type)
  "Return a command line argument list matching IMG-TYPE (a symbol).
IMG-TYPE is an image type symbol, eg \\='png.
Returns a list of command line arguments from ‘totp-auth-file-export-type-map’.
May legitimately return nil, but will signal an error of that image type
has no entry at all."
  (let ((cell (assq img-type totp-auth-file-export-type-map)))
    (if cell
        (cdr cell)
      (error "Image type %S not supported" img-type))))

(defun totp-auth-export-image (file img-type &optional type secrets)
  "Export OTP secrets to FILE as image format IMG-TYPE.
FILE is a path to a file which may or may not exist yet.
IMG-TYPE is a symbol representingh an image type.
\(see ‘totp-auth-image-type-from-filename’ for details).
FILE should match IMG-TYPEs well known extension but this is not enforced.
TYPE is :otpauth or :otpauth-migration, and defaults to :otpauth.
SECRETS is a list of ‘totp-auth-unwrap-otp-blob’ secrets, or nil for all.
\nQR encoding is done by ‘totp-auth-file-export-command’ with the assistance
of ‘totp-auth-file-export-type-map’."
  (unless (totp-auth-check-command totp-auth-file-export-command)
    (error "Command %s not available for QR code export"
           (car totp-auth-file-export-command)))
  (or img-type (error "An image export type (eg 'png) must be specified"))
  (let ((nth 0)
        (export-count 0)
        type-arg arg-list args cmd travel nth-file created)
    (setq type-arg (if (functionp totp-auth-file-export-type-map)
                       (funcall totp-auth-file-export-type-map img-type)
                     (totp-auth-file-export-type-arg img-type))
          arg-list (flatten-list
                    (mapcar (lambda (a)
                              (if (equal "@type@" a) type-arg a))
                            (cdr totp-auth-file-export-command))))
    (with-temp-buffer
      (totp-auth-export-text (current-buffer) type secrets)
      (setq export-count (count-lines (point-min) (point-max)))
      (cond ((zerop export-count) t)
            ((eq export-count 1)
             (goto-char (point-min))
             (setq cmd  (car totp-auth-file-export-command)
                   args (mapcar (lambda (a)
                                  (if (equal "@file@" a) file a))
                                arg-list))
             (apply #'call-process-region
                    (line-beginning-position)
                    (line-end-position)
                    cmd nil t nil args)
             (setq created (list file)))
            (t
             (goto-char (point-min))
             (setq travel (forward-line 0))
             (while (zerop travel)
               (setq nth-file (totp-auth-nthify-file-name file nth)
                     cmd      (car totp-auth-file-export-command)
                     args     (mapcar (lambda (a)
                                        (if (equal "@file@" a) nth-file a))
                                      arg-list))
               (apply #'call-process-region
                      (line-beginning-position)
                      (line-end-position)
                      cmd nil t nil args)
               (setq created (cons nth-file created)
                     travel (forward-line)
                     nth (1+ nth)))
             (setq created (nreverse created)))))
    created))

(defun totp-auth-export-text (file-or-buffer &optional type secrets)
  "Export OTP secrets to FILE-OR-BUFFER.
If the target is a file it should be an epa target (eg a gpg or asc file),
although that is not enforced by this function.
TYPE is :otpauth or :otpauth-migration (and defaults to :otpauth).
SECRETS is a list of ‘totp-auth-unwrap-otp-blob’ secrets or nil,
or a match parameter to ‘totp-auth-secrets’.
If it is nil, all available secrets are exported."
  (or type (setq type :otpauth))
  ;; if it's a string or nil we need to call totp-auth-secrets
  ;; if already a list we assume the caller passed something sensible
  (if (stringp secrets)
      (setq secrets (mapcar #'cdr (totp-auth-secrets secrets)))
    (if (not secrets)
        (setq secrets (mapcar #'cdr (totp-auth-secrets)))))
  (with-current-buffer (if (bufferp file-or-buffer)
                           file-or-buffer
                         (find-file-noselect file-or-buffer))
    (mapc (lambda (s) (insert s "\n"))
          (cond ((eq type :otpauth)
                 (mapcar #'totp-auth-wrap-otpauth-url secrets))
                ((eq type :otpauth-migration)
                 (totp-auth-wrap-otpauth-migration-url secrets))
                (t (error "Unsupported TOTP export type %S" type))))
    (if (buffer-file-name (current-buffer))
        (progn (save-buffer 0) (kill-buffer))
      (display-buffer (current-buffer)))))

(defun totp-auth-export-file (file &optional type secrets)
  "Export TOTP SECRETS to FILE.
FILE is a destination file.
If it matches ‘epa-file-name-regexp’ then a text file is saved.
If ‘totp-auth-image-type-from-filename’ returns an image type for file then
a QR code is generated instead.
TYPE may be :otpauth-migration or :otpauth - which URL scheme to use.
\nSECRETS is a list of ‘totp-auth-unwrap-otp-blob’ secrets, or a string, or nil.
If it is nil all secrets are exported.
If it is a string beginning with ~ or / it is used as a regular expression
to match the labels of the secrets to export from ‘totp-auth-secrets’.
If it begins with = the rest of the string is used as an exact match.
Any other string is used as a substring to look for in the labels."
  (interactive (list (read-file-name "Export to: " nil "totp-auth-export.gpg")
                     (if (y-or-n-p "Use otpauth-migration format? ")
                         :otpauth-migration
                       :otpauth)
                     nil))
  (setq file (expand-file-name file)
        type (if (memq type '(:otpauth :otpauth-migration)) type :otpauth))
  (when (file-exists-p file)
    (error "Export file %S already exists" file))
  (let (img-type epa-ok)
    (setq epa-ok   (string-match epa-file-name-regexp file)
          img-type (totp-auth-image-type-from-filename file))
    (cond (epa-ok   (totp-auth-export-text  file type secrets))
          (img-type (totp-auth-export-image file img-type type secrets))
          (t (error "%S is not an EPA file or supported image format" file)))))

(defun totp-auth-import-file (file)
  "Import an RFC6238 TOTP secret or secrets from FILE.
FILE is processed by ‘totp-auth-load-file’ and each secret extracted
is passed to ‘totp-auth-save-secret’."
  (interactive "fImport OTP Secret(s) from: ")
  (require 'totp-auth)
  (mapc #'totp-auth-save-secret (totp-auth-load-file file)))

(provide 'totp-auth-interop)
;;; totp-auth-interop.el ends here
