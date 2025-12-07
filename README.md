# restclient.el

This is a tool to manually explore and test HTTP REST webservices.
Runs queries from a plain-text query sheet,
displays results as a pretty-printed XML, JSON and even images.

![](http://i.imgur.com/QtCID.png)

# Usage

You can easily install `restclient` using `package.el` from [MELPA](http://melpa.org/).

Alternatively, deploy `restclient.el` into your site-lisp as usual,
then add `(require 'restclient)` to your Emacs start-up file.

Once installed, you can prepare a text file with queries.

`restclient-mode` is a major mode which does a bit of highlighting
and supports a few additional keypresses:

- `C-c C-c`: runs the query under the cursor, tries to pretty-print the response (if possible)
- `C-c C-r`: same, but doesn't do anything with the response, just shows the buffer
- `C-c C-v`: same as `C-c C-c`, but doesn't switch focus to other window
- `C-c C-b`: same as `C-c C-c`, but doesn't show response buffer
- `C-c C-p`: jump to the previous query
- `C-c C-n`: jump to the next query
- `C-c C-.`: mark the query under the cursor
- `C-c C-u`: copy query under the cursor as a curl command
- `C-c C-g`: start a [helm](https://emacs-helm.github.io/helm/) session with sources for variables and requests (if helm is available, of course)
- `C-c n n`: narrow to region of current request (including headers)
- `TAB`: hide/show current request body, only if cursor is on the line with the method of the request
- `C-c C-a`: alternate keybinding for the hide/show functionality
- `C-c C-i`: show information on restclient variables at point
- `C-c C-e`: prompt for environment from which to load variable definitions
- `C-c M-e`: reload the currently active environment
- `C-c '`: Opens the request body for editing in an indirect buffer. (if the package [edit-indirect](https://github.com/Fanael/edit-indirect) is installed)

Hide/show request body is implemented as `restclient-outline-mode` minor mode, which is activated by default via hook for major mode. Remove this hook using `(remove-hook 'restclient-mode-hook 'restclient-outline-mode)` if you don't wish to have this behaviour, or it clashes with any other binding for `TAB` like autocomplete.

Query file example:

    # -*- restclient -*-
    #
    # Gets  all Github APIs, formats JSON, shows response status and headers underneath.
    # Also sends a User-Agent header, because the Github API requires this.
    #
    GET https://api.github.com
    User-Agent: Emacs Restclient

    #
    # XML is supported - highlight, pretty-print
    #
    GET http://www.redmine.org/issues.xml?limit=10

    #
    # It can even show an image!
    #
    GET http://upload.wikimedia.org/wikipedia/commons/6/63/Wikipedia-logo.png
    #
    # A bit of json GET, you can pass headers too
    #
    GET http://jira.atlassian.com/rest/api/latest/issue/JRA-9
    User-Agent: Emacs24
    Accept-Encoding: compress, gzip

    #
    # Post works too, entity just goes after an empty line. Same is for PUT.
    #
    POST https://jira.atlassian.com/rest/api/2/search
    Content-Type: application/json

    {
            "jql": "project = HCPUB",
            "startAt": 0,
            "maxResults": 15,
            "fields": [
                    "summary",
                    "status",
                    "assignee"
            ]
    }
    #
    # And delete, will return not-found error...
    #
    DELETE https://jira.atlassian.com/rest/api/2/version/20

    # Set a variable to the value of your ip address using a jq expression
    GET http://httpbin.org/ip
    -> jq-set-var :my-ip .origin

Lines starting with `#` are considered comments AND also act as separators.

HTTPS and image display requires additional dll's on windows (libtls, libpng, libjpeg etc), which are not in the emacs distribution.

More examples can be found in the `examples` directory.

# Response buffer

Responses are displayed in a buffer in an appropriate major mode (see
`restclient-content-type-modes`).  Additionally, the `view-mode` minor
mode is activated.  We override the `g` keybinding in `view-mode` to
repeat the previous http request.

If you need to edit the response in the response buffer, `e` is the
key to press.  If you then wish to get back into view-mode, `M-x
view-mode` is your friend.  For other keybindings, check the docstring
of the `view-mode` function.

If you have the `json-navigator` package installed, `j` in a response
buffer containing json data will open a hierarchical view of the
response.

# In-buffer variables

For safety, this functionality is disabled by default. Set `restclient-enable-eval` to non-nil to use it.

You declare a variable like this:

    :myvar = the value

or like this:

    :myvar := (some (arbitrary 'elisp))

In second form, the value of variable is evaluated as Emacs Lisp form immediately. Evaluation of variables is done from top to bottom. Only one one-line form for each variable is allowed, so use `(progn ...)` and some virtual line wrap mode if you need more. There's no way to reference earlier declared _restclient_ variables, but you can always use `setq` to save state.

Variables can be multiline too:

    :myvar = <<
    Authorization: :my-auth
    Content-Type: application/json
    User-Agent: SomeApp/1.0
    #

or

    :myvar := <<
    (some-long-elisp
        (code spanning many lines)
    #

`<<` is used to mark a start of multiline value, the actual value is starting on the next line then. The end of such variable value is the same comment marker `#` and last end of line doesn't count, same is for request bodies.

After the var is declared, you can use it in the URL, the header values
and the body.

    # Some generic vars

    :my-auth = 319854857345898457457
    :my-headers = <<
    Authorization: :my-auth
    Content-Type: application/json
    User-Agent: SomeApp/1.0
    #

    # Update a user's name

    :user-id = 7
    :the-name := (format "%s %s %d" 'Neo (md5 "The Chosen") (+ 100 1))

    PUT http://localhost:4000/users/:user-id/
    :my-headers

    { "name": ":the-name" }

Variables can also be set based on the headers or body of a response using the per-request hooks

    # set a variable from a header value
    GET http://httpbin.org/ip
    -> run-hook (restclient-set-var-from-header ":my-length-var" "Content-Length")

    # set a variable :my-ip to the value of your ip address using elisp evaluated in the result buffer
    GET http://httpbin.org/ip
    -> run-hook (restclient-set-var ":my-ip" (cdr (assq 'origin (json-read))))

    # same thing with jq if it's installed
    GET http://httpbin.org/ip
    -> jq-set-var :my-ip .origin

    # alternate syntax with @var definitions are also possible
    GET http://httpbin.org/ip
    -> jq-set-var @my-ip .origin

    # set a variable :my-var using a more complex jq expression (requires jq-mode)
    GET https://httpbin.org/json
    -> jq-set-var :my-var .slideshow.slides[0].title

    # hooks come before the body on POST
    POST http://httpbin.org/post
    -> jq-set-var :test .json.test

    {"test": "foo"}

For basic interoperability with the .http format popularized by Microsoft, variables can also be declared with @:

    @user-id=42

and referenced enclosed in curly braces:

    GET http://localhost:4000/users/{{user-id}}

You can freely mix and match styles in the same file.

More complex variants of .http syntax, like referencing named requests, are not supported, and must instead be re-implemented as native restclient per-request hooks.

# Environment files

In addition to in-buffer variables, variables can be defined in
environments, which in turn can be defined in files.  More than one
environment may be defined per file.  An environment file and
environment is activated by `C-c C-e`, which will prompt for filename
and environment name.

An environment file is a JSON file containing an object with
environment names as keys.  The value of each key is another JSON
object with variable names as keys.

The special environment name "$shared" is always loaded in addition to
the specified environment name.  Values defined in the specified
environment name supersedes the values in she "$shared" section.

After changes to the active environment file, it must be reloaded with
`C-c M-e` before the changes will be discovered by restclient.

For compatibility with other editors, which keep restclient
environments in their settings file, if the loaded JSON file contains
a key "rest-client.environmentVariables", the value of this key is
taken as the environment defintion, instead of the top-level object.

# File uploads

Restclient now allows to specify file path to use as a body, like this:

    POST http://httpbin.org/post
    Content-type: text/plain

    < /etc/nsswitch.conf

The file name can be contained in a variable, like this:

    :myfile = /etc/nsswitch.conf
    POST http://httpbin.org/post
    Content-type: text/plain

    < :myfile

And the request body may also contain surrounding context:

    :myfile = /etc/nsswitch.conf
    POST http://httpbin.org/post
    Content-type: text/plain

    This is the contents of /etc/nsswitch.conf
    < :myfile
    Are you switched on yet?

# Saving responses

Restclient can save or append the body of a response it receives to a file:

    # save request body to a file
    GET http://httpbin.org/ip
    -> save-body /tmp/my-ip.json

    # append request body to a file
    GET http://httpbin.org/ip
    -> append-body /tmp/my-ip.json

### Caveats:

- Multiline variables can be used in headers or body. In URL too, but it doesn't make sense unless it was long elisp expression evaluating to simple value.
- Yet same variable cannot contain both headers and body, it must be split into two and separated by empty line as usual.
- Variables now can reference each other, substitution happens in several passes and stops when there's no more variables. Please avoid circular references. There's customizable safeguard of maximum 10 passes to prevent hanging in this case, but it will slow things down.
- Variable declaration only considered above request line.
- Be careful of what you put in that elisp. No security checks are done, so it can format your hard drive. If there's a parsing or evaluation error, it will tell you in the minibuffer.
- Elisp variables can evaluate to values containing other variable references, this will be substituted too. But you cannot substitute parts of elisp expressions.

# Customization

There are several variables available to customize `restclient` to your liking. Also, all font lock faces are now customizable in `restclient-faces` group too.

### restclient-log-request

__Default: t__

Determines whether restclient logs to the \*Messages\* buffer.

If non-nil, restclient requests will be logged. If nil, they will not be.

### restclient-same-buffer-response

__Default: t__

Re-use same buffer for responses or create a new one each time.

If non-nil, re-use the buffer named by `rest-client-buffer-response-name` for all requests.

If nil, generate a buffer name based on the request type and url, and increment it for subsequent requests.

For example, `GET http://example.org` would produce the following buffer names on 3 subsequent calls:
- `*HTTP GET http://example.org*`
- `*HTTP GET http://example.org*<2>`
- `*HTTP GET http://example.org*<3>`

### restclient-same-buffer-response-name

__Default: \*HTTP Response\*__

Name for response buffer to be used when `restclient-same-buffer-response` is true.

### restclient-inhibit-cookies

__Default: nil__

Inhibit restclient from sending cookies implicitly.

### restclient-response-size-threshold

__Default: 100000__

Size of the response buffer restclient can display without huge performance dropdown.
If response buffer will be more than that, only bare major mode will be used to display it.
Set to `nil` to disable threshold completely.

### restclient-content-type-modes

__Default: '(("text/xml" . xml-mode)
             ("text/plain" . text-mode)
             ("application/xml" . xml-mode)
             ("application/json" . js-mode)
             ("image/png" . image-mode)
             ("image/jpeg" . image-mode)
             ("image/jpg" . image-mode)
             ("image/gif" . image-mode)
             ("text/html" . html-mode))__

An association list mapping content types to buffer modes

### restclient-response-body-only

__Default: nil__

When non-nil, don't include the request details in the response buffer.

### restclient-vars-max-passes

__Default: 10__

Maximum number of recursive variable references.
This is to prevent hanging if two variables reference each other directly or
indirectly.

### restclient-user-agent

__Default: nil__

Controls the User Agent sent by default in requests.  Accepts the same
values as `url-user-agent`, including `default` to let the URL library
compute an appropriate string.  The default `nil` omits the user agent
unless the header is set manually in each requests.

### restclient-query-use-continuation-lines

__Default: nil__

Whether to allow request parameters to span multiple lines.
Default is nil, query parameters must be part of the single line URL in the
request, as the HTTP requires.  If non-nil, continuation lines must directly
follow the initial request line, indented by whitespace.

The value of this parameter also determines how the continuation lines
are interpreted.  Valid values are:
* nil - Do not allow continuation lines (default).
* `literal' - Append each continuation line to the query literally.
* `smart' - Each continuation line is interpreted as a key/value pair,
            separated by =.  Both keys and values are passed through
            `url-hexify-string' before being appended to the query.
            Separators between parameters are added automatically."

### restclient-follow-redirects

__Default: t__

Whether restclient follows redirects.  If t, the default, restclient
will follow up to `url-max-redirections` links in the redirection
chain before giving up.  If nil, no redirections will be followed.  If
an integer, `url-max-redirections` will be temporarily set to that
number.

### restclient-results-in-view-mode

__Default: t__

Determines if the response buffer should be put in view-mode or left
editable.

### restclient-enable-eval

__Default: nil__

Allows evaluation of arbitrary forms in file when non-nil. Never set this when working with untrusted files.

### restclient-strip-http-version

__Default: nil__

Whether or not to strip "HTTP/x.y" from request lines.  `url.el` will
automatically append a HTTP version clause, but many .http files
specify these in the request lines.  If this variable is non-nil,
restclient will strip the clause from the end of the request before
passing it to `url.el`.

# Known issues

- Comment lines `#` act as end of entity. Yes, that means you can't post shell script or anything with hashes as PUT/POST entity. I'm fine with this right now,
but may use more unique separator in future.
- I'm not sure if it handles different encodings, I suspect it won't play well with anything non-ascii. I'm yet to figure it out.
- Variable usages are not highlighted
- If your Emacs is older than 26.1, some GET requests to `localhost` might fail because of that
  [bug](http://debbugs.gnu.org/cgi/bugreport.cgi?bug=17976) in Emacs/url.el. As a workaround you can use `127.0.0.1` instead
  of `localhost`.

# Related 3rd party packages

- [company-restclient](https://github.com/iquiw/company-restclient): It provides auto-completion for HTTP methods and headers in restclient-mode. Completion source is given by know-your-http-well.
- [ob-restclient](https://github.com/alf/ob-restclient.el): An extension to restclient.el for emacs that provides org-babel support.
- [restclient.vim](https://github.com/bounceme/restclient.vim): Brings the restclient to vim! Responses display in vim's internal pager.
- [json-navigator](https://github.com/DamienCassou/json-navigator): Another way of viewing JSON data.
- [edit-indirect](https://github.com/Fanael/edit-indirect): If this
  package is installed, `C-c '` will open an indirect buffer with the
  request body.  We recommend customizing
  `edit-indirect-guess-mode-function` to point to the function
  `restclient-edit-indirect-guess-mode` in order to have JSON request
  bodies open in a better mode than `fundamental-mode`.

# License

Public domain, do whatever you want.

# Author

Pavel Kurnosov <pashky@gmail.com>

# Maintainer

Peder O. Klingenberg <peder@klingenberg.no>
