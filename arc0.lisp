;;; arc0.lisp -- Arc runtime for Common Lisp (SBCL)

(defpackage :arc
  (:use :common-lisp))

(in-package :arc)

;;;; ============================================================
;;;; Utilities
;;;; ============================================================

(defun tnil (x) (if x t nil))

(defun arc-list-p (x) (or (consp x) (null x)))

(defun arc-imap (f l)
  "map over proper or improper list (like Scheme's imap)."
  (cond ((consp l) (cons (funcall f (car l)) (arc-imap f (cdr l))))
        ((null l) nil)
        (t (funcall f l))))

;;;; ============================================================
;;;; Translation from Arc names to CL names and vice-versa
;;;; ============================================================

(defun cl-sym-key (s)
  "Normalize any Arc symbol to an uppercase string key for CL globals."
  (string-upcase (symbol-name s)))

(defun arc-sym-key (s)
  "Normalize any CL symbol to a lowercase string key for Arc globals."
  (string-downcase (symbol-name s)))

(defun cl-sym (name)
  (intern (if (symbolp name) (cl-sym-key name) name) :arc))

(defun arc-sym (name)
  (intern (if (symbolp name) (arc-sym-key name) name) :arc))

(defun arc-sym= (x name)
  "Case-insensitive comparison of symbol X to string NAME."
  (and (symbolp x) (string-equal (symbol-name x) name)))

;;;; ============================================================
;;;; Global variable table  (key = lowercase string)
;;;; ============================================================

(defvar *arc-globals*       (make-hash-table :test #'equal :synchronized t))
(defvar *arc-fn-signatures* (make-hash-table :test #'equal :synchronized t))

(defun arc-global (s)
  (gethash (arc-sym-key s) *arc-globals*))

(defun (setf arc-global) (val s)
  (setf (gethash (arc-sym-key s) *arc-globals*) val))

(defun arc-bound-p (s)
  (nth-value 1 (gethash (arc-sym-key s) *arc-globals*)))

(defun arc-global-ref (s)
  (multiple-value-bind (v present) (gethash (arc-sym-key s) *arc-globals*)
    (if present v (error "Unbound variable: ~A" s))))

(defun (setf arc-global-ref) (val s)
  (setf (arc-global s) val))

(defun arc-global-name (name)
  (intern (concatenate 'string "arc--" (symbol-name name))))

;;; xdef: define an Arc primitive.
;;; (xdef name value)              - bind name to value
;;; (xdef name (args...) body...)  - defun arc--NAME and bind name to it,
;;;                                  so the function shows up in backtraces.
(defmacro xdef (name x &rest body)
  (if (null body)
      `(setf (arc-global ',name) ,x)
      (let ((f (arc-global-name name)))
        `(progn (defun ,f ,x ,@body)
                (xdef ,name #',f)))))

;;;; ============================================================
;;;; Options
;;;; ============================================================

(defvar *arc-atstrings*     t)
(defvar *arc-direct-calls*  nil)
(defvar *arc-explicit-flush* nil)

(xdef sig *arc-fn-signatures*)

(defun arc-declare (key val)
  (let ((flag (not (null val)))
        (k (string-downcase (symbol-name key))))
    (cond ((string= k "atstrings")      (setf *arc-atstrings*      flag))
          ((string= k "direct-calls")   (setf *arc-direct-calls*   flag))
          ((string= k "explicit-flush") (setf *arc-explicit-flush* flag)))
    val))

(xdef declare #'arc-declare)

;;;; ============================================================
;;;; Funcall helpers
;;;; ============================================================

(defun ar-apply-args (args)
  (cond
    ((null args) nil)
    ((null (cdr args)) (car args))
    (t (cons (car args) (ar-apply-args (cdr args))))))

(defun ar-apply (fn args)
  (cond
    ((functionp fn)  (apply fn args))
    ((consp fn)      (nth (car args) fn))
    ((stringp fn)    (char fn (car args)))
    ((hash-table-p fn)
     (let ((v (gethash (car args) fn :arc/missing)))
       (if (eq v :arc/missing)
           (if (cdr args) (cadr args) nil)
           v)))
    (t (error "Function call on non-function: ~S" fn))))

(defun arc-apply (fn &rest args)
  (ar-apply fn (ar-apply-args args)))

(xdef apply #'arc-apply)

(defun arc-call0 (fn)
  (if (functionp fn) (funcall fn) (ar-apply fn nil)))

(defun arc-call1 (fn a)
  (if (functionp fn) (funcall fn a) (ar-apply fn (list a))))

(defun arc-call2 (fn a b)
  (if (functionp fn) (funcall fn a b) (ar-apply fn (list a b))))

(defun arc-call3 (fn a b c)
  (if (functionp fn) (funcall fn a b c) (ar-apply fn (list a b c))))

;;;; ============================================================
;;;; Core primitives
;;;; ============================================================

;;;; ---- nil / t (bound in globals for completeness) ----

(xdef nil nil)
(xdef t   t)

;;;; ---- join / car / cdr ----

(defun arc-join (&optional (a nil) (b nil))
  (cons a b))

(xdef join #'arc-join)

(defun arc-car (x)
  (cond ((consp x) (car x))
        ((null x)  nil)
        (t (error "Can't take car of ~S" x))))

(xdef car #'arc-car)

(defun arc-cdr (x)
  (cond ((consp x) (cdr x))
        ((null x)  nil)
        (t (error "Can't take cdr of ~S" x))))

(xdef cdr #'arc-cdr)

(defun arc-xcar (x) (if (null x) nil (car x)))
(defun arc-xcdr (x) (if (null x) nil (cdr x)))

;;;; ---- scar / scdr ----

(xdef scar (x val)
  (if (stringp x) (setf (char x 0) val) (setf (car x) val))
  val)

(xdef scdr (x val)
  (if (stringp x) (error "Can't set cdr of string")
      (setf (cdr x) val))
  val)

;;;; ---- len ----

(defun arc-len (x)
  (cond ((stringp x)    (length x))
        ((hash-table-p x) (hash-table-count x))
        (t (length x))))

(xdef len #'arc-len)

;;;; ---- comparison operators ----

(defun pairwise (pred lst)
  (cond ((null lst)       t)
        ((null (cdr lst)) t)
        ((null (funcall pred (car lst) (cadr lst))) nil)
        (t (pairwise pred (cdr lst)))))

;; Returns true iff a and b are identical. 
(defun arc-id (a b)
  (or (eql a b)
      (and (numberp a) (numberp b) (= a b))
      (and (stringp a) (stringp b) (string= a b))
      (and (null a) (null b))))

(xdef id #'arc-id)

(defun arc-is2 (a b)
   (or (arc-id a b)
       (cond
         ;; lists
         ((and (consp a) (consp b))
          (and (arc-is2 (car a) (car b))
               (arc-is2 (cdr a) (cdr b))))
         ;; vectors (skip strings — arc-id already handled them)
         ((and (vectorp a) (vectorp b)
               (not (stringp a)) (not (stringp b)))
          (and (= (length a) (length b))
               (loop for i below (length a)
                     always (arc-is2 (aref a i) (aref b i)))))
         ;; tables
         ((and (hash-table-p a) (hash-table-p b))
          (and (eq (hash-table-test a) (hash-table-test b))
               (= (hash-table-count a) (hash-table-count b))
               (loop for k being the hash-keys of a using (hash-value va)
                     always (multiple-value-bind (vb present) (gethash k b)
                              (and present (arc-is2 va vb)))))))))

(defun arc-is (a b &rest args)
  (and (arc-is2 a b)
       (or (null args)
           (apply #'arc-is b args))))

(xdef is #'arc-is)

(defun arc->2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (> x y))
              ((and (stringp x) (stringp y)) (string> x y))
              ((and (symbolp x) (symbolp y))
               (string> (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char> x y))
              (t (> x y)))))

(xdef > (&rest args) (pairwise #'arc->2 args))

(defun arc-<2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (< x y))
              ((and (stringp x) (stringp y)) (string< x y))
              ((and (symbolp x) (symbolp y))
               (string< (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char< x y))
              (t (< x y)))))

(xdef < (&rest args) (pairwise #'arc-<2 args))

;;;; ---- math operators ----

(defun char-or-str-p (x) (or (stringp x) (characterp x)))

(defun arc-+2 (x y)
  (cond ((and (numberp x) (numberp y)) (+ x y))
        ((char-or-str-p x)
         (concatenate 'string
                      (if (characterp x) (string x) x)
                      (if (characterp y) (string y) y)))
        ((and (arc-list-p x) (arc-list-p y)) (append x y))
        (t (+ x y))))

(defun arc-+ (&rest args)
  (cond
    ((null args) 0)
    ((char-or-str-p (car args))
     (apply #'concatenate 'string
            (mapcar (lambda (a)
                      (cond ((stringp a) a)
                            ((characterp a) (string a))
                            ((null a) "")
                            (t (format nil "~A" a))))
                    args)))
    ((arc-list-p (car args)) (apply #'append args))
    (t (apply #'+ args))))

(xdef + #'arc-+)

(xdef - #'-)
(xdef * #'*)
(xdef / #'/)
(xdef mod #'mod)
(xdef expt #'expt)
(xdef sqrt #'sqrt)

;;;; ---- Continuations (escape-only) ----

(defun arc-ccc (f)
  (let ((tag (gensym "K")))
    (catch tag
      (arc-call1 f (lambda (x) (throw tag x))))))

(xdef ccc #'arc-ccc)

;;;; ============================================================
;;;; Higher-level utilities
;;;; ============================================================

(defun arc-car? (l &optional (k :arc/unset) &key (test #'arc-id))
  (and (consp l)
       (if (eq k :arc/unset) (car l)
         (if (functionp k) (funcall k (car l))
           (test (car l) k)))))

(defun arc-caar? (l &optional (k :arc/unset) &key (test #'arc-id))
  (arc-car? (arc-car? l) k :test test))

;;;; ============================================================
;;;; Tagged types
;;;; ============================================================

(defstruct (arc-tagged (:constructor %arc-tag (type rep)))
  type rep)

;;;; ---- Type system ----

(defun arc-type (x)
  (cond
    ((arc-tagged-p x)                  (arc-tagged-type x))
    ((consp x)                         (intern "cons"    :arc))
    ((null x)                          (intern "sym"     :arc))
    ((symbolp x)                       (intern "sym"     :arc))
    ((functionp x)                     (intern "fn"      :arc))
    ((characterp x)                    (intern "char"    :arc))
    ((stringp x)                       (intern "string"  :arc))
    ((and (integerp x) (= x (truncate x))) (intern "int" :arc))
    ((numberp x)                       (intern "num"     :arc))
    ((hash-table-p x)                  (intern "table"   :arc))
    ((and (streamp x) (output-stream-p x)) (intern "output" :arc))
    ((and (streamp x) (input-stream-p x))  (intern "input"  :arc))
    ((typep x 'sb-thread:thread)       (intern "thread"  :arc))
    (t (error "Unknown type: ~S" x))))

(defun arc-tag (type rep)
  (if (and (arc-tagged-p rep)
           (arc-sym= (arc-tagged-type rep) (symbol-name type)))
      rep
      (%arc-tag type rep)))

(defun arc-rep (x)
  (if (arc-tagged-p x) (arc-tagged-rep x) x))

(xdef annotate #'arc-tag)
(xdef type     #'arc-type)
(xdef rep      #'arc-rep)

;;;; ============================================================
;;;; I/O
;;;; ============================================================

(xdef infile (f)
  (open f :direction :input
          :element-type 'character
          :external-format :latin-1))

(xdef infile-binary (f)
  (open f :direction :input
          :element-type '(unsigned-byte 8)))

(xdef outfile (f &rest args)
  (open f :direction :output
          :element-type 'character
          :external-format :latin-1
          :if-exists (if (equal (car args) "append") :append :supersede)
          :if-does-not-exist :create))

(xdef instring  #'make-string-input-stream)
(xdef outstring () (make-string-output-stream))
(xdef inside    #'get-output-stream-string)

(xdef stdout () *standard-output*)
(xdef stdin  () *standard-input*)
(xdef stderr () *error-output*)

(xdef call-w/stdout (port thunk)
  (let ((*standard-output* port)) (arc-call0 thunk)))
(xdef call-w/stdin (port thunk)
  (let ((*standard-input* port)) (arc-call0 thunk)))

(xdef readc (&rest args)
  (let ((c (read-char (if args (car args) *standard-input*) nil nil)))
    (or c nil)))

(xdef readb (&rest args)
  (let ((b (read-byte (if args (car args) *standard-input*) nil nil)))
    (or b nil)))

(xdef peekc (&rest args)
  (let ((c (peek-char nil (if args (car args) *standard-input*) nil nil)))
    (or c nil)))

(xdef writec (c &rest args)
  (write-char c (if args (car args) *standard-output*))
  c)

(xdef writeb (b &rest args)
  (write-byte b (if args (car args) *standard-output*))
  b)

(defun arc-disp-val (x port)
  (cond
    ((stringp x)    (write-string x port))
    ((characterp x) (write-char x port))
    ((null x)       nil)
    ((symbolp x)    (write-string (symbol-name x) port))
    ((consp x)
     (write-char #\( port)
     (arc-write-val (car x) port)
     (let ((rest (cdr x)))
       (loop while rest do
         (cond
           ((consp rest)
            (write-char #\space port)
            (arc-write-val (car rest) port)
            (setf rest (cdr rest)))
           (t
            (write-string " . " port)
            (arc-write-val rest port)
            (setf rest nil)))))
     (write-char #\) port))
    (t (write x :stream port :readably nil))))

(defun arc-write-val (x port)
  (cond
    ((stringp x)    (write x :stream port))  ; quoted
    ((characterp x) (write x :stream port))
    ((null x)       (write-string "nil" port))
    ((eq x t)       (write-string "t" port))
    ((symbolp x)    (write-string (symbol-name x) port))
    ((consp x)
     (write-char #\( port)
     (arc-write-val (car x) port)
     (let ((rest (cdr x)))
       (loop while rest do
         (cond
           ((consp rest)
            (write-char #\space port)
            (arc-write-val (car rest) port)
            (setf rest (cdr rest)))
           (t
            (write-string " . " port)
            (arc-write-val rest port)
            (setf rest nil)))))
     (write-char #\) port))
    (t (write x :stream port :readably nil))))

(xdef disp (&rest args)
  (let ((port (if (cdr args) (cadr args) *standard-output*)))
    (when args (arc-disp-val (car args) port))
    (unless *arc-explicit-flush* (force-output port)))
  nil)

(xdef write (&rest args)
  (let ((port (if (cdr args) (cadr args) *standard-output*)))
    (when args (arc-write-val (car args) port))
    (unless *arc-explicit-flush* (force-output port)))
  nil)

(xdef sread (p eof)
  (arc-read p nil eof))

;;;; ---- coerce ----

(defun parse-num (s)
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (ignore-errors
        (let ((n (read-from-string s)))
          (if (numberp n) n nil))))))

(defun arc-coerce (x type &optional radix)
  (let ((tname (string-downcase
                (if (symbolp type) (symbol-name type) (string type)))))
    (cond
      ((arc-tagged-p x) (error "Can't coerce annotated object"))
      ((string= tname (string-downcase (symbol-name (arc-type x)))) x)
      ((characterp x)
       (cond ((string= tname "int")    (char-code x))
             ((string= tname "string") (string x))
             ((string= tname "sym")    (intern (string x) :arc))
             (t (error "Can't coerce char ~S to ~S" x type))))
      ((and (integerp x) (= x (truncate x)))
       (cond ((string= tname "num")    x)
             ((string= tname "char")   (code-char x))
             ((string= tname "string")
              (if radix
                  (format nil (format nil "~~~DR" radix) x)
                  (format nil "~D" x)))
             (t (error "Can't coerce int ~S to ~S" x type))))
      ((numberp x)
       (cond ((string= tname "int")    (round x))
             ((string= tname "char")   (code-char (round x)))
             ((string= tname "string") (format nil "~A" x))
             (t (error "Can't coerce num ~S to ~S" x type))))
      ((stringp x)
       (cond ((string= tname "sym")    (intern x :arc))
             ((string= tname "cons")   (coerce x 'list))
             ((string= tname "char")
              (if (= (length x) 1)
                  (char x 0)
                  (error "Can't coerce string ~S to char" x)))
             ((string= tname "num")
              (or (parse-num x) (error "Can't coerce string ~S to num" x)))
             ((string= tname "int")
              (if radix
                  (or (ignore-errors (parse-integer x :radix radix))
                      (error "Can't coerce string ~S to int" x))
                  (let ((n (parse-num x)))
                    (if n (round n) (error "Can't coerce string ~S to int" x)))))
             (t (error "Can't coerce string ~S to ~S" x type))))
      ((consp x)
       (cond ((string= tname "string")
              (apply #'concatenate 'string
                     (mapcar (lambda (c)
                               (if (characterp c) (string c) (format nil "~A" c)))
                             x)))
             (t (error "Can't coerce cons to ~S" type))))
      ((null x)
       (cond ((string= tname "string") "")
             (t (error "Can't coerce nil to ~S" type))))
      ((symbolp x)
       (cond ((string= tname "string") (symbol-name x))
             (t (error "Can't coerce sym ~S to ~S" x type))))
      (t x))))

(xdef coerce (x type &rest args) (arc-coerce x type (car args)))

;;;; ============================================================
;;;; Networking  (sb-bsd-sockets)
;;;; ============================================================

(defclass arc-server-socket ()
  ((sock :initarg :sock :reader ass-sock)))

;;; Gray stream wrapper with byte limit
(defclass arc-limited-stream (sb-gray:fundamental-character-input-stream)
  ((source :initarg :source :reader als-src)
   (limit  :initarg :limit  :reader als-limit)
   (count  :initform 0 :accessor als-count)))

(defmethod sb-gray:stream-read-char ((s arc-limited-stream))
  (if (>= (als-count s) (als-limit s))
      :eof
      (let ((c (read-char (als-src s) nil :eof)))
        (when (characterp c) (incf (als-count s)))
        c)))

(defmethod sb-gray:stream-unread-char ((s arc-limited-stream) c)
  (unread-char c (als-src s))
  (when (> (als-count s) 0) (decf (als-count s))))

(defmethod sb-gray:stream-peek-char ((s arc-limited-stream))
  (if (>= (als-count s) (als-limit s))
      :eof
      (peek-char nil (als-src s) nil :eof)))

(defmethod sb-gray:stream-line-column ((s arc-limited-stream)) nil)

(defmethod cl:close ((s arc-limited-stream) &key abort)
  (close (als-src s) :abort abort))

(defun arc-open-socket (port)
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket
                          :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
    (sb-bsd-sockets:socket-bind s #(0 0 0 0) port)
    (sb-bsd-sockets:socket-listen s 50)
    (make-instance 'arc-server-socket :sock s)))

(defun arc-socket-accept (arc-sock)
  ;; socket-accept returns (client-socket ip-vec port)
  (multiple-value-bind (client ipv _port)
      (sb-bsd-sockets:socket-accept (ass-sock arc-sock))
    (declare (ignore _port))
    (let* ((ip  (format nil "~D.~D.~D.~D"
                        (aref ipv 0) (aref ipv 1)
                        (aref ipv 2) (aref ipv 3)))
           (stream (sb-bsd-sockets:socket-make-stream
                    client :input t :output t
                    :element-type :default
                    :external-format :latin-1
                    :buffering :full))
           (lim (make-instance 'arc-limited-stream
                               :source stream :limit 2000000)))
      (list lim stream ip))))

(xdef open-socket  #'arc-open-socket)
(xdef socket-accept #'arc-socket-accept)

(xdef setuid (uid)
  (handler-case
      (sb-alien:alien-funcall
       (sb-alien:extern-alien
        "setuid"
        (function sb-alien:int sb-alien:unsigned))
       uid)
    (error () nil))
  nil)

(xdef client-ip (port) (declare (ignore port)) "unknown")

;;;; ============================================================
;;;; Threading  (sb-thread)
;;;; ============================================================

(xdef new-thread (f)
  (sb-thread:make-thread
   (lambda ()
     (handler-case (arc-call0 f)
       (error (c) (arc-report-error c *error-output*) nil)))
   :name "arc"))

(xdef kill-thread (th) (sb-thread:terminate-thread th) nil)

(xdef break-thread (th)
  (sb-thread:interrupt-thread
   th (lambda () (error "Thread interrupted")))
  nil)

(xdef current-thread () sb-thread:*current-thread*)

(xdef dead (th) (tnil (not (sb-thread:thread-alive-p th))))

(xdef sleep (n) (sleep n) nil)

;;;; ---- atomic-invoke ----

(defvar *arc-mutex* (sb-thread:make-mutex :name "arc"))
(defvar *arc-atomic-owner* nil)

(xdef atomic-invoke (f)
  (if (eq sb-thread:*current-thread* *arc-atomic-owner*)
      (arc-call0 f)
      (sb-thread:with-mutex (*arc-mutex*)
        (let ((*arc-atomic-owner* sb-thread:*current-thread*))
          (arc-call0 f)))))

;;;; ============================================================
;;;; System calls
;;;; ============================================================

(xdef system (cmd)
  (let* ((proc (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                                   :output :stream :wait nil))
         (out  (sb-ext:process-output proc)))
    (loop for c = (read-char out nil nil)
          while c do (write-char c *standard-output*))
    (sb-ext:process-wait proc))
  nil)

(xdef pipe-from (cmd)
  ;; :external-format :latin-1 so each byte from the subprocess becomes
  ;; one Arc char.  Matches the file I/O defaults (see infile/outfile)
  ;; and keeps UTF-8 subprocess output round-trippable through Latin-1
  ;; files (each byte preserved literally).
  (sb-ext:process-output
   (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                       :output :stream :wait nil
                       :external-format :latin-1)))

(xdef getenv (name &optional default)
  ;; treat both "unset" and "set-but-empty" as missing, matching
  ;; shell's ${VAR:-default}.  callers who really need to tell the
  ;; two cases apart can use sb-ext:posix-getenv directly.
  (let ((v (sb-ext:posix-getenv name)))
    (if (or (null v) (string= v ""))
        default
        v)))

;;;; ============================================================
;;;; Tables / hash tables
;;;; ============================================================

(xdef table (&rest args)
  (let ((h (make-hash-table :test #'equal :synchronized t)))
    (when args (arc-call1 (car args) h))
    h))

(xdef maptable (fn table)
  (maphash (lambda (k v) (arc-call2 fn k v)) table)
  table)

(xdef sref (obj val idx)
  (cond
    ((hash-table-p obj)
     (if (null val) (remhash idx obj) (setf (gethash idx obj) val)))
    ((stringp obj)  (setf (char obj idx) val))
    ((consp obj)    (setf (car (nthcdr idx obj)) val))
    (t (error "Can't sref ~S" obj)))
  val)

;;;; ============================================================
;;;; protect / error handling
;;;; ============================================================

(xdef protect (during after)
  (unwind-protect (arc-call0 during) (arc-call0 after)))

(xdef err #'error)

(xdef on-err (errfn f)
  (handler-case (arc-call0 f)
    (error (c) (arc-call1 errfn c))))

(xdef details (c) (format nil "~A" c))

;;;; ============================================================
;;;; Misc primitives
;;;; ============================================================

(xdef rand (&optional n)
  (if n (random n)
      (random 1.0d0)))

(let ((urandom-stream nil))
  (xdef randb ()
    (unless urandom-stream
      (setf urandom-stream
            (open "/dev/urandom"
                  :element-type '(unsigned-byte 8)
                  :direction :input)))
    (read-byte urandom-stream)))

(xdef dir (name)
  (let* ((base (if (or (zerop (length name))
                       (eql (char name (1- (length name))) #\/))
                   name
                   (concatenate 'string name "/")))
         (files (directory (concatenate 'string base "*.*")))
         (subdirs (directory (concatenate 'string base "*/"))))
    (append
     (loop for p in files
           for n = (file-namestring p)
           unless (or (null n) (string= n "")) collect n)
     (mapcar (lambda (p) (car (last (pathname-directory p))))
             subdirs))))

(xdef file-exists (name) (if (probe-file name) name nil))

(xdef dir-exists (name)
  (let ((p (probe-file name)))
    (if (and p (cl:pathname-name p) (string= (cl:pathname-name p) ""))
        nil
        (if (and p (null (pathname-name p))) name nil))))

(xdef rmfile (name) (delete-file name) nil)

(xdef mvfile (old new)
  ; CL rename-file merges new-name with old's truename, which can
  ; double directory components and inherit the old extension.
  ; Avoid both by making new-name absolute and setting type to
  ; :unspecific (explicitly no extension) when the caller provides none.
  (let* ((new-p    (pathname new))
         (new-typed (make-pathname :defaults new-p
                                   :type (or (pathname-type new-p) :unspecific)))
         (new-abs  (merge-pathnames new-typed *default-pathname-defaults*)))
    (rename-file old new-abs))
  nil)

(xdef bound (x) (tnil (arc-bound-p x)))

(xdef newstring #'make-string)

; Native O(n) string slice. `cut` is implemented in arc.arc via
; newstring + per-char copy which is O(n) but with arc-level overhead
; per character; for 1MB inputs that's ~half a second. subseq runs at
; CL speed.
(xdef substr (s start end) (subseq s start end))

; Native: split a string on a single marker character, returning a
; list of alternating string-chunks and integers (the digits between
; pairs of marker characters parsed as ints). Used by news.arc's
; comments-tree cache to break a `tostring`-rendered page with vote-
; link markers into emit-time chunks. Pure arc implementation costs
; ~200ms per 1MB string; this is a few ms.
(xdef split-on-marker-native (s marker-char)
  (let ((markerc (if (characterp marker-char)
                     marker-char
                     (code-char marker-char)))
        (result nil)
        (start 0)
        (len (length s))
        (i 0))
    (loop while (< i len) do
      (cond
        ((char= (aref s i) markerc)
         (push (subseq s start i) result)
         (let ((j (1+ i)))
           (loop while (and (< j len)
                            (not (char= (aref s j) markerc)))
                 do (incf j))
           (push (parse-integer s :start (1+ i) :end j) result)
           (setf start (1+ j))
           (setf i start)))
        (t (incf i))))
    (when (< start len)
      (push (subseq s start len) result))
    (nreverse result)))

(xdef trunc (x) (truncate x))

(xdef exact (x) (tnil (and (integerp x) (= x (truncate x)))))

(defun arc-msec ()
  (floor (* 1000 (/ (get-internal-real-time)
                    internal-time-units-per-second))))
(xdef msec #'arc-msec)

(xdef current-process-milliseconds ()
  (floor (* 1000 (/ (get-internal-run-time)
                    internal-time-units-per-second))))

(xdef current-gc-milliseconds () 0)

;;; Unix time: CL universal time is from 1900; Unix from 1970
(defconstant +cl-to-unix+ 2208988800)

(xdef seconds () (- (get-universal-time) +cl-to-unix+))

(xdef timedate (&rest args)
  (let* ((unix (if args (car args) (- (get-universal-time) +cl-to-unix+)))
         (ut   (+ unix +cl-to-unix+))
         (d    (multiple-value-list (decode-universal-time ut 0))))
    ;; sec min hr day mon yr ...
    (list (first d) (second d) (third d) (fourth d) (fifth d) (sixth d))))

(xdef sin  #'sin)
(xdef cos  #'cos)
(xdef tan  #'tan)
(xdef asin #'asin)
(xdef acos #'acos)
(xdef atan #'atan)
(xdef log  #'log)

(xdef flushout () (force-output *standard-output*) t)

(xdef ssyntax  (x) (tnil (ssyntax-p x)))
(xdef ssexpand (x) (if (ssyntax-p x) (expand-ssyntax x) x))

(xdef quit () (sb-ext:exit))

(xdef memory () (sb-kernel:dynamic-usage))

;;;; ---- close / force-close ----

(xdef close (&rest args)
  (dolist (p args)
    (ignore-errors
      (cond ((typep p 'arc-server-socket) (sb-bsd-sockets:socket-close (ass-sock p)))
            ((streamp p) (cl:close p))
            (t nil))))
  nil)

(xdef force-close (&rest args)
  (dolist (p args)
    (ignore-errors
      (cond ((typep p 'arc-server-socket) (sb-bsd-sockets:socket-close (ass-sock p)))
            ((streamp p) (cl:close p :abort t))
            (t nil))))
  nil)

;;;; ============================================================
;;;; REPL
;;;; ============================================================

(defvar *arc-last-err* nil)

(defun arc-report-error (c &optional (stream *standard-output*))
  (setf *arc-last-err* c)
  (format stream "Error: ~A~%" c)
  (format stream "Backtrace for: ~A~%" sb-thread:*current-thread*)
  (let ((i 0)
        (count 30)
        (stop nil))
    (sb-debug:map-backtrace
     (lambda (frame)
       (when (and (not stop) (< i count))
         ;; Print frames under :invert readtable case so mixed-case
         ;; symbol names (like arc--CAR) come out without |...| escapes.
         ;; All-lowercase and all-uppercase names still print in their
         ;; canonical form; only mixed-case ones change.
         (let ((text (with-output-to-string (s)
                       (let ((*print-pretty* nil)
                             (*readtable* (copy-readtable *readtable*)))
                         (setf (readtable-case *readtable*) :invert)
                         (sb-debug::print-frame-call frame s :number nil)))))
           (format stream "~D: ~A~%" i text)
           (incf i)
           (let ((name (sb-di:debug-fun-name (sb-di:frame-debug-fun frame))))
             (when (and (symbolp name)
                        (string= (symbol-name name) "ARC-BOOT"))
               (setf stop t))))))))
  (terpri stream)
  (force-output stream))

(defun arc-tl ()
  (format t "Use (quit) to quit, (arc:arc-tl) to return here after an interrupt.~%")
  (arc-tl2))

(defun arc-tl2 ()
  (format t "arc> ")
  (force-output *standard-output*)
  (block iter
    (handler-bind ((sb-sys:interactive-interrupt
                    (lambda (c)
                      (declare (ignore c))
                      (clear-input *standard-input*)
                      (terpri)
                      (return-from iter)))
                   (error (lambda (c)
                            (arc-report-error c)
                            ;; Drop the rest of the buffered line so a
                            ;; mid-token read error doesn't leave stray
                            ;; delimiters that re-trigger on each prompt.
                            (clear-input *standard-input*)
                            (return-from iter))))
      (let ((expr (arc-read *standard-input* nil :eof)))
        (cond
          ((or (eq expr :eof) (equal expr :a)) (return-from arc-tl2 'done))
          (t
           (let ((val (arc-eval expr)))
             (arc-write-val val *standard-output*)
             (terpri)
             (setf (arc-global '|that|)     val)
             (setf (arc-global '|thatexpr|) expr)))))))
  (arc-tl2))

