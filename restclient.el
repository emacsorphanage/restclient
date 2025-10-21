;;; restclient.el --- An interactive HTTP client for Emacs  -*- lexical-binding: t; -*-
;;
;; Public domain.

;; Author: Pavel Kurnosov <pashky@gmail.com>
;; Maintainer: Peder O. Klingenberg <peder@klingenberg.no>
;; Created: 01 Apr 2012
;; Keywords: http comm tools
;; URL: https://github.com/emacsorphanage/restclient
;; Package-Requires: ((emacs "26.1") (compat "30.1.0.0"))
;; Version: 1.0

;; This file is not part of GNU Emacs.
;; This file is public domain software. Do what you want.

;;; Commentary:
;;
;; This is a tool to manually explore and test HTTP REST
;; webservices.  Runs queries from a plain-text query sheet, displays
;; results as a pretty-printed XML, JSON and even images.

;;; Code:
;;
(require 'url)
(require 'json)
(require 'outline)
(require 'view)
(require 'compat)
(eval-when-compile (require 'subr-x))
(eval-when-compile
  (if (version< emacs-version "26")
      (require 'cl)
    (require 'cl-lib)))

(eval-when-compile
  (unless (functionp 'hash-table-contains-p)
    (let ((missing (make-symbol "missing")))
      (defsubst hash-table-contains-p (key table)
        "Return non-nil if TABLE has an element with KEY."
        (declare (side-effect-free t))
        (not (eq (gethash key table missing) missing))))))

(defgroup restclient nil
  "An interactive HTTP client for Emacs."
  :group 'tools)

(defcustom restclient-log-request t
  "Log restclient requests to *Messages*."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-same-buffer-response t
  "Re-use same buffer for responses or create a new one each time."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-same-buffer-response-name "*HTTP Response*"
  "Name for response buffer."
  :group 'restclient
  :type 'string)

(defcustom restclient-response-size-threshold 100000
  "Size of the response restclient can display without performance impact."
  :group 'restclient
  :type 'integer)

(defvar restclient-threshold-multiplier 10
  "In how many times size-threshold should be exceed to use fundamental mode.")

(defcustom restclient-info-buffer-name "*Restclient Info*"
  "Name for info buffer."
  :group 'restclient
  :type 'string)

(defcustom restclient-inhibit-cookies nil
  "Inhibit restclient from sending cookies implicitly."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-content-type-modes '(("text/xml" . xml-mode)
                                           ("text/plain" . text-mode)
                                           ("application/xml" . xml-mode)
                                           ("application/json" . js-mode)
                                           ("image/png" . image-mode)
                                           ("image/jpeg" . image-mode)
                                           ("image/jpg" . image-mode)
                                           ("image/gif" . image-mode)
                                           ("text/html" . html-mode))
  "An association list mapping content types to buffer modes."
  :group 'restclient
  :type '(alist :key-type string :value-type symbol))

(defcustom restclient-response-body-only nil
  "When parsing response, only return its body."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-vars-max-passes 10
  "Maximum number of recursive variable references.
This is to prevent hanging if two variables reference each other directly or
indirectly."
  :group 'restclient
  :type 'integer)

(defcustom restclient-user-agent nil
  "User Agent used in the requests.
Passed to `url-user-agent'.  See that variable for valid values.
Default is nil, to allow requests to set User-Agent as a header."
  :group 'restclient
  :type '(choice
          (string :tag "A static User-Agent string")
          (function :tag "Call a function to get the User-Agent string")
          (const :tag "No User-Agent at all" :value nil)
          (const :tag "An string auto-generated according to `url-privacy-level'"
                 :value default)))

(defcustom restclient-query-use-continuation-lines nil
  "Whether to allow request parameters to span multiple lines.
Default is nil, query parameters must be part of the single line URL in the
request, as the HTTP requires.  If non-nil, continuation lines must directly
follow the initial request line, indented by whitespace.

The value of this parameter also determines how the continuation lines
are interpreted. Valid values are:
* nil - Do not allow continuation lines (default).
* `literal' - Append each continuation line to the query literally.
* `smart' - Each continuation line is interpreted as a key/value pair,
            separated by =.  Both keys and values are passed through
            `url-hexify-string' before being appended to the query.
            Separators between parameters are added automatically."
  :group 'restclient
  :type '(choice
          (const :tag "Do not allow continuation lines.")
          (const :tag "Append continuation lines literally."
                 :value literal)
          (const :tag "Continuation liens are key/value pairs."
                 :value smart)))

(defcustom restclient-follow-redirects t
  "Whether restclient follows redirects.
If t, the default, restclient will follow up to `url-max-redirections'
links in the redirection chain before giving up.  If nil, no
redirections will be followed.  If an integer, `url-max-redirections'
will be temporarily set to that number."
  :group 'restclient
  :type '(choice
          (const :tag "Follow redirects" :value t)
          (const :tag "Do not follow redirects" :value nil)
          (integer :tag "Follow this many redirects")))

(defcustom restclient-results-in-view-mode t
  "Determines if the response buffer should be put in view-mode or left
editable."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-enable-eval nil
  "Whether eval features are enabled.
Do not set to non-nil when working with untrusted documents."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-strip-http-version nil
  "Whether or not to strip \"HTTP/x.y\" from request lines.
`url.el' will automatically append a HTTP version clause,
but many .http files specify these in the request lines.
If this variable is non-nil, restclient will strip the clause
from the end of the request before passing it to `url.el'."
  :group 'restclient
  :type 'boolean)

(defgroup restclient-faces nil
  "Faces used in Restclient Mode."
  :group 'restclient
  :group 'faces)

(defface restclient-variable-name-face
  '((t (:inherit font-lock-preprocessor-face)))
  "Face for variable name."
  :group 'restclient-faces)

(defface restclient-variable-string-face
  '((t (:inherit font-lock-string-face)))
  "Face for variable value (string)."
  :group 'restclient-faces)

(defface restclient-variable-elisp-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs Lisp)."
  :group 'restclient-faces)

(defface restclient-variable-multiline-face
  '((t (:inherit font-lock-doc-face)))
  "Face for multi-line variable value marker."
  :group 'restclient-faces)

(defface restclient-variable-usage-face
  '((t (:inherit restclient-variable-name-face)))
  "Face for variable usage.
\(only used when headers/body is represented as a single variable, not
highlighted when variable appears in the middle of other text)."
  :group 'restclient-faces)

(defface restclient-method-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for HTTP method."
  :group 'restclient-faces)

(defface restclient-url-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs Lisp)."
  :group 'restclient-faces)

(defface restclient-file-upload-face
  '((t (:inherit restclient-variable-multiline-face)))
  "Face for highlighting upload file paths."
  :group 'restclient-faces)

(defface restclient-header-name-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for HTTP header name."
  :group 'restclient-faces)

(defface restclient-header-value-face
  '((t (:inherit font-lock-string-face)))
  "Face for HTTP header value."
  :group 'restclient-faces)

(defface restclient-request-hook-face
  '((t (:inherit font-lock-preprocessor-face)))
  "Face for single request hook indicator."
  :group 'restclient-faces)

(defface restclient-request-hook-name-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for single request hook type names."
  :group 'restclient-faces)

(defface restclient-request-hook-args-face
  '((t (:inherit font-lock-string-face)))
  "Face for single request hook type arguments."
  :group 'restclient-faces)


(defvar restclient-within-call nil)

(defvar restclient-request-time-start nil)
(defvar restclient-request-time-end nil)

(defvar restclient-var-overrides nil
  "An alist of vars that will override any set in the file.
Also where dynamic vars set on callbacks are stored.")

(defvar restclient-var-defaults nil
  "An alist of fallback values for vars not defined elsewhere.")

(defvar restclient-current-env-file nil
  "The file containing current environment definitions.")

(defvar restclient-current-env-name nil
  "Current environment name, defined in `restclient-current-env-file'.")

(defvar restclient-result-handlers '()
  "A registry of available completion hooks.
Stored as an alist of name -> (hook-creation-func . description)")

(defvar restclient-curr-request-functions nil
  "A list of functions to run once when the next request is loaded.")

(defvar restclient-response-loaded-hook nil
  "Hook run after response buffer is formatted.")

(defvar restclient-http-do-hook nil
  "Hook to run before making request.")

(defvar restclient-response-received-hook nil
  "Hook run after data is loaded into response buffer.")

(defvar restclient-current-request-marker (make-marker)
  "Marker keeping track of the last executed request.")

(defvar-local restclient--header-start-position nil
  "Position in the buffer where headers start.")


(defconst restclient-comment-separator "#")
(defconst restclient-comment-start-regexp (concat "^" restclient-comment-separator))
(defconst restclient-comment-not-regexp (concat "^[^" restclient-comment-separator "]"))
(defconst restclient-empty-line-regexp "^\\s-*$")

(defconst restclient-method-url-regexp
  "^[[:blank:]]*\\(GET\\|POST\\|DELETE\\|PUT\\|HEAD\\|OPTIONS\\|PATCH\\|PROPFIND\\) \\(.*\\)$")

(defconst restclient-url-continuation-line-regexp
  "^[[:blank:]]+\\(.*\\)$")

(defconst restclient-url-continuation-key-value-regexp
  "\\([^= ]+\\)\\s-*=\\s-*\\(.*\\)$")

(defconst restclient-url-version-regexp "[[:blank:]]+HTTP/[0-9]+\\.[0-9]+$")

(defconst restclient-method-body-prohibited-regexp
  "^GET\\|HEAD$")

(defconst restclient-header-regexp
  "^\\([^](),/:;@[\\{}= \t]+\\): \\(.*\\)$")

(defconst restclient-use-var-regexp
  "^:\\([^: \n]+\\)\\|{{\\([^} \n]+\\)}}$")

(defconst restclient-var-regexp
  (concat "^\\(?::\\([^:= ]+\\)\\|@\\([^:= ]+\\)\\)[ \t]*\\(:?\\)=[ \t]*\\(<<[ \t]*\n\\(\\(.*\n\\)*?\\)" restclient-comment-separator "\\|\\([^<].*\\)$\\)"))

(defconst restclient-svar-regexp
  "^\\(:[^:= ]+\\)[ \t]*=[ \t]*\\(.+?\\)$")

(defconst restclient-evar-regexp
  "^\\(:[^: ]+\\)[ \t]*:=[ \t]*\\(.+?\\)$")

(defconst restclient-mvar-regexp
  "^\\(:[^: ]+\\)[ \t]*:?=[ \t]*\\(<<\\)[ \t]*$")

(defconst restclient-file-regexp
  "^<[ \t]*\\([^<>\n\r]+\\)[ \t]*$")

(defconst restclient-content-type-regexp
  "^Content-[Tt]ype: \\(\\w+\\)/\\(?:[^\\+\r\n]*\\+\\)*\\([^;\r\n]+\\)")

(defconst restclient-response-hook-regexp
  "^\\(->\\) \\([^[:space:]]+\\) +\\(.*\\)$")

;; The following disables the interactive request for user name and
;; password should an API call encounter a permission-denied response.
;; This API is meant to be usable without constant asking for username
;; and password.

(define-advice url-http-handle-authentication (:around (orig &rest args) restclient-disable-auth)
  "Disable interactive request for username/password."
  (if restclient-within-call
      t ;; Means authorization failed.
    (apply orig args)))

(define-advice url-cache-extract (:around (orig &rest args) restclient-disable-cache)
  "Disable cache."
  (unless restclient-within-call
    (apply orig args)))

(defvar restclient--globals-stack
  (make-hash-table))

(defmacro restclient--push-global-var (var new-val)
  "Save current value of VAR, and set VAR to NEW-VAL.
Workaround for Emacs bug#61916"
  `(progn
     (push ,var (gethash ',var restclient--globals-stack ()))
     (setq-default ,var ,new-val)))

(defmacro restclient--pop-global-var (var)
  "Restore old global value of VAR, if any."
  `(when (and (hash-table-contains-p ',var restclient--globals-stack)
              (< 0 (length (gethash ',var restclient--globals-stack))))
     (setq-default ,var (pop (gethash ',var restclient--globals-stack)))))

(defun restclient-http-do (method url headers entity &rest handle-args)
  "Send ENTITY and HEADERS to URL as a METHOD request."
  (if restclient-log-request
      (message "HTTP %s %s Headers:[%s] Body:[%s]" method url headers entity))
  (let ((url-request-method (encode-coding-string method 'us-ascii))
        (url-request-extra-headers '())
        (url-request-data (if (string-match restclient-method-body-prohibited-regexp method)
                              nil
                            (encode-coding-string entity 'utf-8))))

    (restclient--push-global-var url-mime-charset-string (url-mime-charset-string))
    (restclient--push-global-var url-mime-language-string nil)
    (restclient--push-global-var url-mime-encoding-string nil)
    (restclient--push-global-var url-mime-accept-string nil)
    (restclient--push-global-var url-user-agent restclient-user-agent)
    (restclient--push-global-var url-max-redirections
                                 (cond
                                  ((not restclient-follow-redirects)
                                   0)
                                  ((integerp restclient-follow-redirects)
                                   restclient-follow-redirects)
                                  (t
                                   url-max-redirections)))

    (dolist (header headers)
      (let* ((mapped (assoc-string (downcase (car header))
                                   '(("from" . url-personal-mail-address)
                                     ("accept-encoding" . url-mime-encoding-string)
                                     ("accept-charset" . url-mime-charset-string)
                                     ("accept-language" . url-mime-language-string)
                                     ("accept" . url-mime-accept-string)))))

        (if mapped
            (set (cdr mapped) (encode-coding-string (cdr header) 'us-ascii))
          (let* ((hkey (encode-coding-string (car header) 'us-ascii))
                 (hvalue (encode-coding-string (cdr header) 'us-ascii)))
            (setq url-request-extra-headers (cons (cons hkey hvalue) url-request-extra-headers))))))

    (setq restclient-within-call t)
    (setq restclient-request-time-start (current-time))
    (run-hooks 'restclient-http-do-hook)
    (url-retrieve url 'restclient-http-handle-response
                  (append (list method url (if restclient-same-buffer-response
                                               restclient-same-buffer-response-name
                                             (format "*HTTP %s %s*" method url)))
                          handle-args)
                  nil restclient-inhibit-cookies)))

(defun restclient--preferred-mode (content-type)
  "Look up the user's preferred mode for handling content of type CONTENT-TYPE.

The user defines their preferences in `restclient-content-type-modes'."
  (cdr (assoc-string content-type restclient-content-type-modes t)))

(defun restclient-prettify-response (method url status)
  "Format the result of the API call in a pleasing way.
METHOD, URL and STATUS are displayed along with the response headers."
  (save-excursion
    (let ((start (point))
          (guessed-mode)
          (end-of-headers))
      (while (and (not (looking-at restclient-empty-line-regexp))
                  (eq (progn
                        (when (looking-at restclient-content-type-regexp)
                          (setq guessed-mode
                                (restclient--preferred-mode (concat
                                                             (match-string-no-properties 1)
                                                             "/"
                                                             (match-string-no-properties 2)))))
                        (forward-line))
                      0)))
      (setq end-of-headers (point))
      (while (and (looking-at restclient-empty-line-regexp)
                  (eq (forward-line) 0)))
      (unless guessed-mode
        (setq guessed-mode
              (or (assoc-default nil
                                 ;; magic mode matches
                                 `(("<\\?xml " . ,(restclient--preferred-mode "application/xml"))
                                   ("{\\s-*\"" . ,(restclient--preferred-mode "application/json")))
                                 (lambda (re _dummy)
                                   (looking-at re)))
                  (restclient--preferred-mode "application/json"))))
      (let ((headers (buffer-substring-no-properties start end-of-headers)))
        (when guessed-mode
          (delete-region start (point))
          (unless (eq guessed-mode (restclient--preferred-mode "image/png"))
            (cond ((and restclient-response-size-threshold
                        (> (buffer-size) (* restclient-response-size-threshold
                                            restclient-threshold-multiplier)))
                   (fundamental-mode)
                   (setq comment-start (let ((guessed-mode guessed-mode))
                                         (with-temp-buffer
                                           (apply  guessed-mode '())
                                           comment-start)))
                   (message
                    "Response is too huge, using fundamental-mode to display it!"))
                  ((and restclient-response-size-threshold
                        (> (buffer-size) restclient-response-size-threshold))
                   (delay-mode-hooks (apply guessed-mode '()))
                   (message
                    "Response is too big, using bare %s to display it!" guessed-mode))
                  (t
                   (apply guessed-mode '())))
            (if (fboundp 'font-lock-flush)
                (font-lock-flush)
              (with-no-warnings
                (font-lock-fontify-buffer))))

          (cond
           ((eq guessed-mode (restclient--preferred-mode "application/xml"))
            (goto-char (point-min))
            (while (search-forward-regexp "\>[ \\t]*\<" nil t)
              (backward-char) (insert "\n"))
            (indent-region (point-min) (point-max)))

           ((eq guessed-mode (restclient--preferred-mode "image/png"))
            (let* ((img (buffer-string)))
              (delete-region (point-min) (point-max))
              (fundamental-mode)
              (insert-image (create-image img nil t))))

           ((eq guessed-mode (restclient--preferred-mode "application/json"))
            (let ((json-special-chars (remq (assoc ?/ json-special-chars) json-special-chars))
		  ;; Emacs 27 json.el uses `replace-buffer-contents' for
		  ;; pretty-printing which is great because it keeps point and
		  ;; markers intact but can be very slow with huge minimized
		  ;; JSON.  We don't need that here.
		  (json-pretty-print-max-secs 0))
              (ignore-errors (json-pretty-print-buffer)))
            (restclient-prettify-json-unicode)))

          (goto-char (point-max))
          (or (eq (point) (point-min)) (insert "\n"))
	  (unless restclient-response-body-only
            (let ((hstart (point)))
              (setq restclient--header-start-position hstart)
              (insert method " " url "\n")
              (cl-loop for (data event) on (reverse status) by #'cddr
                       when (eq event :redirect)
                       do (insert "Redirect: " data "\n"))
              (insert headers)
              (insert (format "Request duration: %fs\n" (float-time (time-subtract restclient-request-time-end restclient-request-time-start))))
              (unless (member guessed-mode (list (restclient--preferred-mode "image/png")
                                                 (restclient--preferred-mode "text/plain")))
		(comment-region hstart (point))))))))))

(defun restclient-prettify-json-unicode ()
  "Convert hex representations of unicode to characters."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "\\\\[Uu]\\([0-9a-fA-F]\\{4\\}\\)" nil t)
      (replace-match (char-to-string (decode-char 'ucs (string-to-number (match-string 1) 16))) t nil))))

(defun restclient-http-handle-response (status method url bufname raw stay-in-window suppress-response-buffer)
  "Switch to the buffer returned by `url-retrieve'.
The buffer contains the raw HTTP response sent by the server.
STATUS: http status of the response.
METHOD: http method of the request.
URL: url of the request.
BUFNAME; the name of the buffer in which to display results
RAW: if non-nil, the raw response will be displayed, instead of a pretty-printed
     version.
STAY-IN-WINDOW: if non-nil, do not switch to the output buffer, only show it.
SUPPRESS-RESPONSE-BUFFER: do not show the reponse at all."
  (setq restclient-within-call nil)
  (setq restclient-request-time-end (current-time))
  (restclient--pop-global-var url-mime-charset-string)
  (restclient--pop-global-var url-mime-language-string)
  (restclient--pop-global-var url-mime-encoding-string)
  (restclient--pop-global-var url-mime-accept-string)
  (restclient--pop-global-var url-user-agent)
  (restclient--pop-global-var url-max-redirections)
  (if (= (point-min) (point-max))
      (let ((error-status (plist-get status :error)))
        (if error-status
            (error (format "%s: %s" (car error-status) (cdr error-status)))
          (error "Empty response from server")))
    (when (buffer-live-p (current-buffer))
      (with-current-buffer (restclient-decode-response
                            (current-buffer)
                            bufname
                            restclient-same-buffer-response)
        (run-hooks 'restclient-response-received-hook)
        (unless raw
          (restclient-prettify-response method url status))
        (buffer-enable-undo)
        (when restclient-results-in-view-mode
          (view-mode-enter))
        (restclient--setup-response-buffer-map)
        (run-hooks 'restclient-response-loaded-hook)
        (unless suppress-response-buffer
          (if stay-in-window
              (display-buffer (current-buffer) t)
            (switch-to-buffer-other-window (current-buffer)))))
      (message "")))) ;; Request complete, remove the "Contacting host"-message from url-http

(defun restclient-decode-response (raw-http-response-buffer target-buffer-name same-name)
  "Decode the HTTP response.
Use the charset (encoding) specified in the Content-Type header.  If no
charset is specified, default to UTF-8.
RAW-HTTP-RESPONSE-BUFFER: the buffer where the URL library has deposited the
   reponse.
TARGET-BUFFER-NAME: the name of the buffer into which we will place the decoded
   result.
SAME-NAME: if non-nil, reuse the target buffer if it exists, otherwise generate
   a fresh buffer."
  (let* ((charset-regexp "^Content-Type.*charset=\\([-A-Za-z0-9]+\\)")
         (image? (save-excursion
                   (search-forward-regexp "^Content-Type.*[Ii]mage" nil t)))
         (encoding (if (save-excursion
                         (search-forward-regexp charset-regexp nil t))
                       (intern (downcase (match-string 1)))
                     'utf-8)))
    (if image?
        ;; Don't attempt to decode. Instead, just switch to the raw HTTP response buffer and
        ;; rename it to target-buffer-name.
        (with-current-buffer raw-http-response-buffer
          ;; We have to kill the target buffer if it exists, or `rename-buffer'
          ;; will raise an error.
          (when (get-buffer target-buffer-name)
            (kill-buffer target-buffer-name))
          (rename-buffer target-buffer-name)
          raw-http-response-buffer)
      ;; Else, switch to the new, empty buffer that will contain the decoded HTTP
      ;; response. Set its encoding, copy the content from the unencoded
      ;; HTTP response buffer and decode.
      (let ((decoded-http-response-buffer
             (get-buffer-create
              (if same-name target-buffer-name (generate-new-buffer-name target-buffer-name)))))
        (with-current-buffer decoded-http-response-buffer
          (view-mode-exit t)
          (setq buffer-file-coding-system encoding)
          (setq restclient--header-start-position (point-min))
          (save-excursion
            (erase-buffer)
            (insert-buffer-substring raw-http-response-buffer))
          (kill-buffer raw-http-response-buffer)
          (condition-case nil
              (decode-coding-region (point-min) (point-max) encoding)
            (error
             (message (concat "Error when trying to decode http response with encoding: "
                              (symbol-name encoding)))))
          decoded-http-response-buffer)))))

(defun restclient-current-min ()
  "Return the position of the start of the current request."
  (save-excursion
    (beginning-of-line)
    (if (looking-at restclient-comment-start-regexp)
        (if (re-search-forward restclient-comment-not-regexp (point-max) t)
            (line-beginning-position) (point-max))
      (if (re-search-backward restclient-comment-start-regexp (point-min) t)
          (line-beginning-position 2)
        (point-min)))))

(defun restclient-current-max ()
  "Return the position of the end of the current request."
  (save-excursion
    (if (re-search-forward restclient-comment-start-regexp (point-max) t)
        (max (- (line-beginning-position) 1) 1)
      (progn (goto-char (point-max))
             (if (looking-at "^$") (- (point) 1) (point))))))

(defun restclient-replace-all-in-string (replacements string)
  "Replace variables in STRING.
REPLACEMENTS is an alist containing the current variable values.
Return a string with variables replaced with their values, possibly recursively."
  (if replacements
      (let ((current string)
            (prev nil)
            (regexp (regexp-opt (append
                                 (mapcar #'(lambda (r)
                                             (format ":%s" (car r)))
                                         replacements)
                                 (mapcar #'(lambda (r)
                                             (format "{{%s}}" (car r)))
                                         replacements))))
            (pass restclient-vars-max-passes)
            (continue t))
        (while (and continue (> pass 0))
          (setq pass (- pass 1))
          (setq prev current)
          (setq current (replace-regexp-in-string
                         regexp
                         (lambda (key)
                           (setq key (restclient-sanitize-var-name key))
                           (cdr (assoc key replacements)))
                         current t t))
          (setq continue (not (equal prev current))))
        current)
    string))

(defun restclient-replace-all-in-header (replacements header)
  "Calls `restclient-replace-all-in-string' on a header value.
REPLACEMENTS is an alist containing the current variable values.
HEADER is an alist element (<header-name> . <value>).
Returns a new alist elements with the same header name, and a variable-expanded
value."
  (cons (car header)
        (restclient-replace-all-in-string replacements (cdr header))))

(defun restclient-chop (text)
  "Remove newline at the end of TEXT, if any."
  (if text (replace-regexp-in-string "\n$" "" text) nil))

(defun restclient-set-env (env-file env-name)
  "Define variables for the current environment.

ENV-FILE is a json file as defined in
https://learn.microsoft.com/en-us/aspnet/core/test/http-files?view=aspnetcore-9.0#environment-files.
Alternatively, a VS Code settings file with the environments defined under the
key rest-client.environmentVariables is acceptable.

ENV-NAME is the name of a specific environment defined in ENV-FILE.

The special environment name `$shared' will always load in addition to the
requested env, with lower priority."
  (interactive (let* ((default-dir (when restclient-current-env-file
                                     (file-name-directory restclient-current-env-file)))
                      (default-file (when restclient-current-env-file
                                      (file-name-nondirectory restclient-current-env-file)))
                      (filename
                       (read-file-name "Environment file name: "
                                       default-dir default-file t))
                      (envs (mapcar #'car (restclient-parse-env-file filename))))
                 (list filename (completing-read "Environment name: " envs nil t))))
  (setq restclient-current-env-file env-file)
  (setq restclient-current-env-name env-name)
  (restclient-reload-current-env))

(defun restclient-parse-env-file (filename)
  "Read environments from FILENAME.
Environments contain sets of variable definitions.  A file can contain multiple
environment definitions."
  (let* ((json-key-type 'string)
         (envs (json-read-file filename)))
      (when (assoc "rest-client.environmentVariables" envs)
        (setq envs (cdr (assoc "rest-client.environmentVariables" envs))))
      envs))

(defun restclient-reload-current-env ()
  "Refresh variable definitions from current environment definition."
  (interactive)
  (when (and restclient-current-env-file restclient-current-env-name)
    (let* ((envs (restclient-parse-env-file restclient-current-env-file))
           (shared-name "$shared")
           (nonshared (when (not (equal restclient-current-env-name shared-name))
                        (cdr (assoc restclient-current-env-name envs)))))
      (setq restclient-var-defaults
            (append nonshared
                    (cdr (assoc shared-name envs)))))
    (message "Environment \"%s\" loaded" restclient-current-env-name)))

(defun restclient-find-vars-before-point ()
  "Determine which variables are valid at the current position."
  (let ((vars nil)
        (bound (point)))
    (save-match-data
     (save-excursion
       (goto-char (point-min))
       (while (search-forward-regexp restclient-var-regexp bound t)
         (let ((name (or (match-string-no-properties 1)
                         (match-string-no-properties 2)))
               (should-eval (> (length (match-string 3)) 0))
               (value (or (restclient-chop (match-string-no-properties 5)) (match-string-no-properties 4))))
	   (setq value (cond
			((not should-eval)
			 value)
			((not restclient-enable-eval)
			 (warn "Evaluation disabled in current buffer: `restclient-enable-eval' is nil")
			 value)
			(t
			 (restclient-eval-var value))))
           (push (cons name value) vars)))
       (append restclient-var-overrides vars restclient-var-defaults)))))

(defun restclient-eval-var (string)
  "Evaluate the Lisp code contained in STRING.
The result of the evaluation is returned as a string."
  (with-output-to-string (princ (eval (read string)))))

(defun restclient-make-header (&optional string)
  "Create an alist element from STRING.
Match data must be set by caller."
  (cons (match-string-no-properties 1 string)
        (match-string-no-properties 2 string)))

(defun restclient-parse-headers (string)
  "Create a header alist from STRING."
  (let ((start 0)
        (headers '()))
    (while (string-match restclient-header-regexp string start)
      (setq headers (cons (restclient-make-header string) headers)
            start (match-end 0)))
    headers))

(defun restclient-get-response-headers ()
  "Returns alist of current response headers."
  (let* ((start restclient--header-start-position)
         (headers-end (+ 1 (or (string-match "\n\n" (buffer-substring-no-properties start (point-max)))
                               (buffer-size))))
         (headers-commented-p (and (< 1 start) ;; Catches raw response buffers
                                   (not (member major-mode (list (restclient--preferred-mode "image/png")
                                                                 (restclient--preferred-mode "text/plain"))))))
         (headers-string (buffer-substring-no-properties start headers-end)))
    (when headers-commented-p
      ;; Temporarily uncomment to extract string
      (uncomment-region start headers-end)
      (setq headers-end (+ 1 (or (string-match "\n\n" (buffer-substring-no-properties start (point-max)))
                                 (buffer-size))))
      (setq headers-string (buffer-substring-no-properties start headers-end))
      (comment-region start headers-end))
    (restclient-parse-headers headers-string)))

(defun restclient-set-var-from-header (var header)
  "Record a dynamic variable VAR from response headers.
HEADER is the name of the header to look up in the response."
  (restclient-set-var var (cdr (assoc header (restclient-get-response-headers)))))

(defun restclient-read-file (path)
  "Return the contents of the file PATH as a string."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun restclient-replace-path-with-contents (entity)
  "Include file contents in request.
ENTITY is the request body, Possibly with `< /file/path' embeded, which
will be replaced with the contents of `/file/path' if it exists.  If
`/file/path' does not exist, the construct may be an XML tag or other
data, not a file embedding, and will not be replaced."
  (replace-regexp-in-string
   restclient-file-regexp
   (lambda (match)
     (let ((filename (match-string 1 match)))
       (if (file-exists-p filename)
           (restclient-read-file filename)
         match)))
   entity t t))

(defun restclient-parse-body (entity vars)
  "Prepare a request body for sending.
Replace variables with their values, and include file contents.
ENTITY is the body of the request (a string), VARS is an alist of currently
defined variables."
  (restclient-replace-path-with-contents (restclient-replace-all-in-string vars entity)))

(defun restclient-parse-hook (cb-type args-offset args)
  "Parse a hook definition.
CB-TYPE is the callback type, must be a previously registered type of handler.
ARGS-OFFSET is the position in the buffer where the arguments to / contents of
the hook begin.  ARGS is the string from after the CB-TYPE to the end of the
line.

Registered callback handlers will typically use only one of ARGS or ARGS-OFFSET."
  (if-let* ((handler (assoc cb-type restclient-result-handlers)))
      (funcall (cadr handler) args args-offset)
    `(lambda ()
       (message "Unknown restclient hook type %s" ,cb-type))))

(defun restclient-register-result-func (name creation-func description)
  "Register a new callback type.
NAME: The name of the callback type.
CREATION-FUNC: A function that interprets the rest of the hook definition and
returns a function that will be called in the context of the result buffer.
DESCRIPTION: Descriptive text."
  (let ((new-cell (cons name (cons creation-func description))))
    (setq restclient-result-handlers (cons new-cell restclient-result-handlers))))

(defun restclient-sanitize-var-name (var-name)
  "Return the name of a variable, without decorations like `:' or `{{}}'.
VAR-NAME: a variable with or without decorations."
  (save-match-data
    (cond
     ((string-match restclient-use-var-regexp var-name)
      (setq var-name (or (match-string 1 var-name) (match-string 2 var-name))))
     ((string-match "^@\\([^@ \n]+\\)$" var-name)
      (setq var-name (match-string 1 var-name)))))
  var-name)

(defun restclient-remove-var (var-name)
  "Remove VAR-NAME from the list of dynamic variables."
  (let ((var-name (restclient-sanitize-var-name var-name)))
    (setq restclient-var-overrides (compat-call assoc-delete-all var-name restclient-var-overrides))))

(defun restclient-set-var (var-name value)
  "Set VAR-NAME to VALUE for any subsequent requests."
  (let ((var-name (restclient-sanitize-var-name var-name)))
    (restclient-remove-var var-name)
    (setq restclient-var-overrides (cons (cons var-name value) restclient-var-overrides))))

(defun restclient-get-var-at-point (var-name buffer-name buffer-pos)
  "Look up the value of VAR-NAME in the current context.
Context is defined by environment, dynamically set variables, and variables
defined in BUFFER-NAME prior to BUFFER-POS."
  ;(message (format "getting var %s from %s at %s" var-name buffer-name buffer-pos))
  (let* ((var-name (restclient-sanitize-var-name var-name))
         (vars-at-point  (save-excursion
			   (switch-to-buffer buffer-name)
			   (goto-char buffer-pos)
			   ;; if we're called from a restclient buffer we need to lookup vars before the current hook or evar
			   ;; outside a restclient buffer only globals are available so moving the point wont matter
			   (re-search-backward "^:\\|->" (point-min) t)
			   (restclient-find-vars-before-point))))
    (restclient-replace-all-in-string vars-at-point (cdr (assoc var-name vars-at-point)))))

(defmacro restclient-get-var (var-name)
  "Get the value of VAR-NAME in the current buffer."
  (let ((buf-name (buffer-name (current-buffer)))
	(buf-point (point)))
    `(restclient-get-var-at-point ,var-name ,buf-name ,buf-point)))

(defun restclient-single-request-function ()
  "Execute the callbacks/hooks defined for the current request."
  (dolist (f restclient-curr-request-functions)
    (save-excursion
      (ignore-errors
       (funcall f))))
  (setq restclient-curr-request-functions nil)
  (remove-hook 'restclient-response-loaded-hook 'restclient-single-request-function))

(defun restclient--parse-continuation-line (vars line separator)
  "Read a key/value pair from LINE.
Return a %-encoded line preceeded by SEPARATOR.
Restclient variables in are expanded in keys and values separately,
using definitions passed in VARS."
  (if (string-match restclient-url-continuation-key-value-regexp line)
      (let ((key (match-string-no-properties 1 line))
            (val (match-string-no-properties 2 line)))
        (concat separator
                (url-hexify-string (restclient-replace-all-in-string vars key))
                "="
                (url-hexify-string (restclient-replace-all-in-string vars val))))
    (error "Line is not a valid key/value pair")))

(defun restclient-http-parse-current-and-do (func &rest args)
  "Execute FUNC with the current request.
FUNC will receive the http method, url, headers and body of the request around
point as arguments, with ARGS included as the final argument."
  (set-marker restclient-current-request-marker (point))
  (save-excursion
    (goto-char (restclient-current-min))
    (when (re-search-forward restclient-method-url-regexp (point-max) t)
      (let* ((vars (restclient-find-vars-before-point))
             (method (match-string-no-properties 1))
             (url (restclient-replace-all-in-string
                   vars (string-trim (match-string-no-properties 2))))
             (q-param-separator (if (memq ?? (string-to-list url))
                                    "&"
                                  "?"))
             (headers '()))
        (forward-line)
        (while (and restclient-query-use-continuation-lines
                    (looking-at restclient-url-continuation-line-regexp))
          (let ((line (match-string-no-properties 1)))
            (setq url
                  (concat url
                          (cond
                           ((eq 'literal restclient-query-use-continuation-lines)
                            (restclient-replace-all-in-string vars (string-trim line)))
                           ((eq 'smart restclient-query-use-continuation-lines)
                            (restclient--parse-continuation-line vars line q-param-separator))
                           (t
                            (error "Unknown value for `restclient-query-use-continuation-lines': %s"
                                   restclient-query-use-continuation-lines))))))
          (setq q-param-separator "&")
          (forward-line))
        (when restclient-strip-http-version
          (setq url (replace-regexp-in-string restclient-url-version-regexp "" url)))
        (while (cond
		((looking-at restclient-response-hook-regexp)
		 (when-let* ((hook-function (restclient-parse-hook (match-string-no-properties 2)
				 				   (match-end 2)
					 			   (match-string-no-properties 3))))
		   (push hook-function restclient-curr-request-functions)))
                ((and (looking-at restclient-header-regexp) (not (looking-at restclient-empty-line-regexp)))
                 (setq headers (cons (restclient-replace-all-in-header vars (restclient-make-header)) headers)))
                ((looking-at restclient-use-var-regexp)
                 (setq headers (append headers (restclient-parse-headers (restclient-replace-all-in-string vars (match-string 0)))))))
          (forward-line))
        (when (looking-at restclient-empty-line-regexp)
          (forward-line))
	(when restclient-curr-request-functions
	  (add-hook 'restclient-response-loaded-hook 'restclient-single-request-function))
        (let* ((cmax (restclient-current-max))
               (entity (restclient-parse-body (buffer-substring (min (point) cmax) cmax) vars)))
          (apply func method url headers entity args))))))

(defun restclient-copy-curl-command ()
  "Formats the request as a curl command and copies the command to the clipboard."
  (interactive)
  (restclient-http-parse-current-and-do
   '(lambda (method url headers entity)
      (let ((include-arg (if restclient-response-body-only
                             ""
                           "-i"))
            (header-args
             (mapconcat (lambda (header)
                          (format "-H \"%s: %s\" " (car header) (cdr header)))
                        headers))
            (method-arg (format "-X %s" method))
            (url-arg (format "\"%s\"" url))
            (body-arg (if (< 0 (length entity))
                          (format "-d '%s'"
                                  (replace-regexp-in-string "'" "'\\\\''" entity))
                        "")))
        (kill-new (format  "curl %s %s %s %s %s"
                           include-arg
                           header-args
                           method-arg
                           url-arg
                           body-arg)))
      (message "curl command copied to clipboard."))))


(defun restclient-elisp-result-function (_args offset)
  "This is a hook constructor function.
Read one S-expression starting from OFFSET.
Return a function of 0 arguments that evaluates that S-expression.
ARGS is ignored."
  (goto-char offset)
  (if restclient-enable-eval
      (let ((form (macroexpand-all (read (current-buffer)))))
	(lambda ()
	  (eval form)))
    (lambda ()
      (warn "Evaluation disabled in current buffer: `restclient-enable-eval' is nil"))))

(restclient-register-result-func
 "run-hook" #'restclient-elisp-result-function
 "Call the provided (possibly multi-line) elisp when the result
  buffer is formatted. Equivalent to a restclient-response-loaded-hook
  that only runs for this request.
  eg. -> run-hook (message \"my hook called\")" )

(defun restclient-save-body-function (filename append)
  "Save the response to the FILENAME given in args.
If APPEND is non-nil, appends to the file."
  (lambda ()
    (let* ((start (point-min))
           (end (if (< start restclient--header-start-position)
                    (1- restclient--header-start-position)
                  (point-max))))
      (write-region start end filename append)
      (message "Response saved to \"%s\"" filename))))

(restclient-register-result-func
 "save-body" #'(lambda (args _offset)
                 (restclient-save-body-function args nil))
 "Save the response body to file.  The argument to the hook is the
name of the file to save.
eg. -> save-body /tmp/myfile.json")

(restclient-register-result-func
 "append-body" #'(lambda (args _offset)
                   (restclient-save-body-function args t))
 "Append the response body to file.  The argument to the hook is the
name of the file to append to.
eg. -> append-body /tmp/myfile.json")

;;;###autoload
(defun restclient-http-send-current (&optional raw stay-in-window suppress-response-buffer)
  "Sends current request.
Optional argument RAW don't reformat response if t.
Optional argument STAY-IN-WINDOW do not move focus to response buffer if t.
Optional argument SUPPRESS-RESPONSE-BUFFER do not display response buffer if t."
  (interactive)
  (restclient-http-parse-current-and-do 'restclient-http-do raw stay-in-window suppress-response-buffer))

;;;###autoload
(defun restclient-http-send-current-raw ()
  "Sends current request and get raw result.
\(no reformatting or syntax highlight of XML, JSON or images)."
  (interactive)
  (restclient-http-send-current t))

;;;###autoload
(defun restclient-http-send-current-stay-in-window ()
  "Send current request and keep focus in request window."
  (interactive)
  (restclient-http-send-current nil t))

;;;###autoload
(defun restclient-http-send-current-suppress-response-buffer ()
  "Send current request but don't show response buffer."
  (interactive)
  (restclient-http-send-current nil nil t))

(defun restclient-jump-next ()
  "Jump to next request in buffer."
  (interactive)
  (let ((last-min nil))
    (while (not (eq last-min (goto-char (restclient-current-min))))
      (goto-char (restclient-current-min))
      (setq last-min (point))))
  (goto-char (+ (restclient-current-max) 1))
  (goto-char (restclient-current-min)))

(defun restclient-jump-prev ()
  "Jump to previous request in buffer."
  (interactive)
  (let* ((current-min (restclient-current-min))
         (end-of-entity
          (save-excursion
            (progn (goto-char (restclient-current-min))
                   (while (and (or (looking-at "^\s*\\(#.*\\)?$")
                                   (eq (point) current-min))
                               (not (eq (point) (point-min))))
                     (forward-line -1)
                     (beginning-of-line))
                   (point)))))
    (unless (eq (point-min) end-of-entity)
      (goto-char end-of-entity)
      (goto-char (restclient-current-min)))))

(defun restclient-mark-current ()
  "Mark current request."
  (interactive)
  (goto-char (restclient-current-min))
  (set-mark-command nil)
  (goto-char (restclient-current-max))
  (backward-char 1)
  (setq deactivate-mark nil))

(defun restclient-repeat-last-request ()
  "Repeat the last executed request."
  (interactive)
  (when (marker-buffer restclient-current-request-marker)
    (save-excursion
      (with-current-buffer (marker-buffer restclient-current-request-marker)
        (goto-char restclient-current-request-marker)
        (restclient-http-send-current-suppress-response-buffer)))))

(declare-function json-navigator-navigate-after-point "ext:json-navigate")

(defun restclient-json-navigate-response ()
  "Run the current json response through json-navigator, if it's installed."
  (interactive)
  (cond ((not (fboundp 'json-navigator-navigate-after-point))
         (message "json-navigator is not installed"))
        ((not (eq major-mode (restclient--preferred-mode "application/json")))
         (message "Response buffer is not in JS mode"))
        (t
         (goto-char (point-min))
         (json-navigator-navigate-after-point))))

(declare-function org-toggle-pretty-entities "org")
(declare-function org-table-iterate-buffer-tables "org-table")

(defun restclient-show-info ()
  "Display a buffer with information about the current restclient context."
  (interactive)
  (let ((vars-at-point (restclient-find-vars-before-point)))
    (cl-labels ((non-overidden-vars-at-point ()
		  (seq-filter (lambda (v)
				(null (assoc (car v) restclient-var-overrides)))
			      vars-at-point))
		(sanitize-value-cell (var-value)
		  (replace-regexp-in-string
                   "\n" "|\n| |"
                   (replace-regexp-in-string
                    "\|" "\\\\vert{}"
                    (replace-regexp-in-string
                     "_" "\\\\under{}"
		     (restclient-replace-all-in-string vars-at-point var-value)))))
                (sanitize-name-cell (var-name)
                  (replace-regexp-in-string "_" "\\\\under{}" var-name))
		(var-row (var-name var-value)
		  (insert "|" (sanitize-name-cell var-name) "|" (sanitize-value-cell var-value) "|\n"))
		(var-table (table-name)
		  (insert (format "* %s\n|--|\n|Name|Value|\n|---|\n" table-name)))
		(var-table-footer ()
		  (insert "|--|\n\n")))

      (with-current-buffer (get-buffer-create restclient-info-buffer-name)
        (view-mode-exit t)
	;; insert our info
	(erase-buffer)

	(insert "\Restclient Info\ \n\n")

	(var-table "Dynamic Variables")
	(dolist (dv restclient-var-overrides)
	  (var-row (car dv) (cdr dv)))
	(var-table-footer)

	(var-table "Vars at current position")
	(dolist (dv (non-overidden-vars-at-point))
	  (var-row (car dv) (cdr dv)))
	(var-table-footer)

        (insert "* Active environment\n|--|\n|File|Environment name|\n|--|\n")
        (when (or restclient-current-env-file restclient-current-env-name)
          (insert "|" (or restclient-current-env-file "") "|" (or restclient-current-env-name "") "|\n"))
        (var-table-footer)

	;; registered callbacks
	(var-table "Registered request hook types")
	(dolist (handler-name (delete-dups (mapcar 'car restclient-result-handlers)))
	  (var-row handler-name (cddr (assoc handler-name restclient-result-handlers))))
    	(var-table-footer)

	(insert "\n\n'q' to exit\n")
	(org-mode)
	(org-toggle-pretty-entities)
	(org-table-iterate-buffer-tables)
	(outline-show-all)
	(view-mode-enter)
	(goto-char (point-min))))
    (switch-to-buffer-other-window restclient-info-buffer-name)))

(defun restclient-narrow-to-current ()
  "Narrow to region of current request."
  (interactive)
  (narrow-to-region (restclient-current-min) (restclient-current-max)))

(defun restclient-toggle-body-visibility ()
  "Hide or show the body of the current request.
Hide/show only happens if point is on the first line of a request."
  (interactive)
  ;; If we are not on the HTTP call line, don't do anything
  (let ((at-header (save-excursion
                     (beginning-of-line)
                     (looking-at restclient-method-url-regexp))))
    (when at-header
      (save-excursion
        (end-of-line)
        ;; If the overlays at this point have 'invisible set, toggling
        ;; must make the region visible. Else it must hide the region

        ;; This part of code is from org-hide-block-toggle method of
        ;; Org mode
        (let ((overlays (overlays-at (point))))
          (if (memq t (mapcar
                       (lambda (o)
                         (eq (overlay-get o 'invisible) 'outline))
                       overlays))
              (outline-flag-region (point) (restclient-current-max) nil)
            (outline-flag-region (point) (restclient-current-max) t)))) t)))

(defun restclient-toggle-body-visibility-or-indent ()
  "Hide of show the body of the current request, or indent current line."
  (interactive)
  (unless (restclient-toggle-body-visibility)
    (indent-for-tab-command)))

(defconst restclient-mode-keywords
  (list (list restclient-method-url-regexp '(1 'restclient-method-face) '(2 'restclient-url-face))
        (list restclient-svar-regexp '(1 'restclient-variable-name-face) '(2 'restclient-variable-string-face))
        (list restclient-evar-regexp '(1 'restclient-variable-name-face) '(2 'restclient-variable-elisp-face t))
        (list restclient-mvar-regexp '(1 'restclient-variable-name-face) '(2 'restclient-variable-multiline-face t))
        (list restclient-use-var-regexp '(1 'restclient-variable-usage-face))
        (list restclient-file-regexp '(0 'restclient-file-upload-face))
        (list restclient-header-regexp '(1 'restclient-header-name-face t) '(2 'restclient-header-value-face t))
	(list restclient-response-hook-regexp '(1 ' restclient-request-hook-face t)
	      '(2 'restclient-request-hook-name-face t)
	      '(3 'restclient-request-hook-args-face t))))

(defconst restclient-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\# "<" table)
    (modify-syntax-entry ?\n ">#" table)
    table))

(defvar restclient-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'restclient-http-send-current)
    (define-key map (kbd "C-c C-r") 'restclient-http-send-current-raw)
    (define-key map (kbd "C-c C-v") 'restclient-http-send-current-stay-in-window)
    (define-key map (kbd "C-c C-b") 'restclient-http-send-current-suppress-response-buffer)
    (define-key map (kbd "C-c C-n") 'restclient-jump-next)
    (define-key map (kbd "C-c C-p") 'restclient-jump-prev)
    (define-key map (kbd "C-c C-.") 'restclient-mark-current)
    (define-key map (kbd "C-c C-u") 'restclient-copy-curl-command)
    (define-key map (kbd "C-c n n") 'restclient-narrow-to-current)
    (define-key map (kbd "C-c C-i") 'restclient-show-info)
    (define-key map (kbd "C-c C-e") 'restclient-set-env)
    (define-key map (kbd "C-c M-e") 'restclient-reload-current-env)
    map)
  "Keymap for `restclient-mode'.")

(defvar restclient-response-buffer-map
  (let ((map (make-sparse-keymap))
        (view-mode-map (cdr (assoc 'view-mode minor-mode-map-alist))))
    (set-keymap-parent map view-mode-map)
    (define-key map (kbd "g") 'restclient-repeat-last-request)
    (define-key map (kbd "j") 'restclient-json-navigate-response)
    map)
  "Keymap for restclient responses.
Added to the default `view-mode-map' when displaying responses in view mode.")

(defun restclient--setup-response-buffer-map ()
  "Override `view-mode' keymap in response buffers."
  (push `(view-mode . ,restclient-response-buffer-map)
        minor-mode-overriding-map-alist))

(define-minor-mode restclient-outline-mode
  "Minor mode to allow show/hide of request bodies by TAB."
      :init-value nil
      :lighter nil
      :keymap '(("\t" . restclient-toggle-body-visibility-or-indent)
                ("\C-c\C-a" . restclient-toggle-body-visibility-or-indent))
      :group 'restclient)

;;;###autoload
(define-derived-mode restclient-mode fundamental-mode "REST Client"
  "Turn on restclient mode."
  (set (make-local-variable 'comment-start) "# ")
  (set (make-local-variable 'comment-start-skip) "# *")
  (set (make-local-variable 'comment-column) 48)

  (set (make-local-variable 'font-lock-defaults) '(restclient-mode-keywords))
  ;; We use outline-mode's method outline-flag-region to hide/show the
  ;; body. As a part of it, it sets 'invisibility text property to
  ;; 'outline. To get ellipsis, we need 'outline to be in
  ;; buffer-invisibility-spec
  (add-to-invisibility-spec '(outline . t)))

(add-hook 'restclient-mode-hook 'restclient-outline-mode)
(add-hook 'restclient-mode-hook #'(lambda ()
                                    (setq imenu-generic-expression
                                          `((nil ,restclient-method-url-regexp 0)))))

(provide 'restclient)

(eval-after-load 'helm
  '(ignore-errors (require 'restclient-helm)))

(eval-after-load 'jq-mode
  '(ignore-errors (require 'restclient-jq)))

;;; restclient.el ends here
