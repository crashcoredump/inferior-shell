#+xcvb (module (:depends-on ("pkgdcl")))

(in-package :inferior-shell)
(in-readtable :fare-quasiquote)


(defclass process-spec (simple-print-object-mixin) ())

(defclass pipe-spec (process-spec)
  ((processes
    :type list
    :initarg :processes :reader pipe-processes)))

(defclass redirection (simple-print-object-mixin) ())

(defclass file-redirection (redirection)
  ((fd
    :type integer
    :initarg :fd :reader redirection-fd)
   (symbol ;; shell symbol
    :type symbol
    :initarg :symbol :reader redirection-symbol)
   (flags ;; direction and flags for cl:open
    :type list
    :initarg :flags :reader redirection-flags)
   (pathname
    :type (or string pathname)
    :initarg :pathname :reader redirection-pathname)))

(defclass fd-redirection (redirection)
  ;; when you'd tell a shell $new >& $old,
  ;; you mean the C code dup2(old,new)
  ;; The new descriptor is copied from the old one
  ;; (any previously bound value is closed).
  ((old-fd
    :type integer
    :initarg :old-fd :reader redirection-old-fd)
   (new-fd
    :type integer
    :initarg :new-fd :reader redirection-new-fd)))

(defclass close-redirection (redirection)
  ;; close a fd
  ((old-fd
    :type integer
    :initarg :old-fd :reader redirection-old-fd)))

(defun make-file-redirection (symbol fd pn flags)
  (make-instance 'file-redirection
                 :symbol symbol :fd fd :pathname pn :flags flags))

(defun make-fd-redirection (old-fd new-fd)
  (make-instance 'fd-redirection :old-fd old-fd :new-fd new-fd))

(defun make-close-redirection (old-fd)
  (make-instance 'close-redirection :old-fd old-fd))

(defgeneric print-process-spec (r &optional s)
  (:documentation "Print a process specification in a way suitable for consumption by a shell"))

(defmethod print-process-spec ((r file-redirection) &optional s)
  (with-output-stream (s)
    (with-slots (fd symbol pathname) r
      (when (eq symbol '!)
        (error "Can't print ad-hoc redirection ~S" r))
      (unless (= fd (case symbol ((< <>) 0) (otherwise 1)))
        (format s "~D " fd))
      (format s "~A " symbol)
      (xcvb-driver:escape-command (list pathname) s))))

(defmethod print-process-spec ((r fd-redirection) &optional s)
  (with-output-stream (s)
    (with-slots (new-fd old-fd) r
      (case new-fd
        (0 (format s "<& ~D" old-fd))
        (1 (format s ">& ~D" old-fd))
        (otherwise (format s "~D >& ~D" new-fd old-fd))))))

(defmethod print-process-spec ((r close-redirection) &optional s)
  (with-output-stream (s)
    (with-slots (old-fd) r
      (case old-fd
        (0 (princ "<& -" s))
        (1 (princ ">& -" s))
        (otherwise (format s "~D >& -" old-fd))))))

(defclass command-spec (process-spec)
  ((arguments
    :type list
    :initarg :arguments :reader command-arguments)
   (redirections
    :type list
    :initarg :redirections :reader command-redirections)))

(defclass command-parse ()
  ((arguments-r
    :type list :initform nil
    :accessor clps-arguments-r)
   (redirections-r
    :type list :initform nil
    :accessor clps-redirections-r)
   (current-argument
    :type (or null stream) :initform nil
    :accessor clps-current-argument)))

(defgeneric ensure-argument (command-parse))
(defgeneric flush-argument (command-parse))
(defgeneric new-argument (command-parse))
(defgeneric extend-argument (command-parse string))
(defgeneric add-argument (command-parse string))
(defgeneric add-redirection (command-parse redirection))
(defgeneric command-parse-results (command-parse))

(defmethod ensure-argument ((c command-parse))
  (unless (clps-current-argument c)
    (setf (clps-current-argument c) (make-string-output-stream)))
  (values))

(defmethod flush-argument ((c command-parse))
  (with-accessors ((current clps-current-argument)
                   (arguments clps-arguments-r)) c
    (when current
      (push (get-output-stream-string current) arguments)
      (close current)
      (setf current nil)))
  (values))

(defmethod new-argument ((c command-parse))
  (flush-argument c)
  (ensure-argument c)
  (values))

(defmethod extend-argument ((c command-parse) x)
  (ensure-argument c)
  (princ x (clps-current-argument c))
  (values))

(defmethod add-argument ((c command-parse) (argument string))
  (flush-argument c)
  (push argument (clps-arguments-r c))
  (values))

(defmethod add-redirection ((c command-parse) redirection)
  (push redirection (clps-redirections-r c))
  (values))

(defmethod command-parse-results ((c command-parse))
  (flush-argument c)
  (prog1
      (make-instance
       'command-spec
       :arguments (nreverse (clps-arguments-r c))
       :redirections (nreverse (clps-redirections-r c)))
    (setf (clps-arguments-r c) nil
          (clps-redirections-r c) nil
          (clps-current-argument c) nil)))

(defun parse-process-spec (spec)
  (match spec
    (`(pipe ,@args)
      (make-instance
       'pipe-spec :processes
       (loop :for process :in (mapcar 'parse-process-spec args)
         :nconc (if (typep process 'pipe-spec)
                    (pipe-processes process)
                    (list process)))))
    (`(,* ,@*)
      (let ((c (make-instance 'command-parse)))
        (dolist (elem spec)
          (parse-command-spec-top-token c elem))
        (command-parse-results c)))
    (*
     (error "Invalid process spec ~S" spec))))

(defun parse-command-spec-top-token (c x)
  (labels
      ((r (x)
         (add-redirection c x))
       (f (sym fd pn flags)
         (r (make-file-redirection sym fd pn flags)))
       (fd (old new)
         (r (make-fd-redirection old new)))
       (cl (old)
         (r (make-close-redirection old)))
       (c (x)
         (match x
           (`(! ,fd ,pn ,@flags) (f '! fd pn flags))
           (`(- ,fd) (cl fd))
           (`(< ,pn) (c `(< 0 ,pn)))
           (`(< ,fd ,pn)
             (f '< fd pn
                '(:input :if-does-not-exist :error)))
           (`(<> ,pn) (c `(<> 0 ,pn)))
           (`(<> ,pn)
             (f '<> 0 pn
                '(:io :if-exists :overwrite :if-does-not-exist :error)))
           (`(> ,pn) (c `(> 1 ,pn)))
           (`(> ,fd ,pn)
             (f '> fd pn
                '(:output :if-exists :error :if-does-not-exist :create)))
           (`(>! ,pn) (c `(>! 1 ,pn)))
           (`(>! ,fd ,pn)
             (f '>! fd pn
                '(:output :if-exists :supersede :if-does-not-exist :create)))
           (`(>> ,pn) (c `(>> 1 ,pn)))
           (`(>> ,fd ,pn)
             (f '>> fd pn
                '(:output :if-exists :append :if-does-not-exist :error)))
           (`(>>! ,pn) (c `(>> 1 ,pn)))
           (`(>>! ,fd ,pn)
             (f '>>! fd pn
                '(:output :if-exists :append :if-does-not-exist :create)))
           (`(<& ,old-fd -)
             (cl old-fd))
           (`(<& ,new-fd ,old-fd)
             (fd old-fd new-fd))
           (`(>& ,old-fd -)
             (cl old-fd))
           (`(>& ,new-fd ,old-fd)
             (fd old-fd new-fd))
           (`(<& -)
             (cl 0))
           (`(>& -)
             (cl 1))
           (`(>& ,pn)
             (c `(> 1 ,pn))
             (c `(>& 2 1)))
           (`(>&! ,pn)
             (c `(>! 1 ,pn))
             (c `(>& 2 1)))
           (`(>>& ,pn)
             (c `(>> 1 ,pn))
             (c `(>& 2 1)))
           (`(>>&! ,pn)
             (c `(>>! 1 ,pn))
             (c `(>& 2 1)))
           (*
            (flush-argument c)
            (parse-command-spec-token c x)
            (flush-argument c))))
       (a (x)
         (add-argument c x)))
    (etypecase x
      (string (a x))
      (character (a (format nil "-~a" x)))
      (null ())
      (keyword (a (format nil "--~(~a~)" x)))
      (symbol (a (string-downcase x)))
      (cons (c x)))))

(defun parse-command-spec-token (c x)
  (labels
      ((e (x) (extend-argument c x))
       (p (x)
         (etypecase x
           (string (e x))
           (character (e (format nil "-~a" x)))
           ((eql -) (e " "))
           (null ())
           (keyword (e (format nil "--~(~a~)" x)))
           (symbol (e (string-downcase x)))
           (cons (c x))))
       (c (x)
         (match x
           (`(,(of-type string) ,@*) ;; recurse
             (map () #'p x))
           (`(+ ,@args) ;; recurse (explicit call)
             (map () #'p args))
           (`(* ,@args) ;; splice
             (loop :for (arg . rest) :on args :do
               (p arg) (when rest (flush-argument c))))
           (`(quote ,@args) ;; quote
             (e (xcvb-driver:escape-command
                 (parse-command-spec-tokens args))))
           (*
            (error "Unrecognized command-spec token ~S" x)))))
    (p x)))

(defun parse-command-spec-tokens (spec)
  (let ((c (make-instance 'command-parse)))
    (parse-command-spec-token c `(+ ,@spec))
    (command-arguments (command-parse-results c))))

(defmethod print-process-spec ((spec command-spec) &optional s)
  (with-slots (arguments redirections) spec
    (with-output-stream (s)
      (xcvb-driver:escape-command arguments s)
      (when redirections
        (loop :for r :in redirections :do
          (princ " " s) (print-process-spec r s))))))

(defmethod print-process-spec ((spec pipe-spec) &optional s)
  (with-output-stream (s)
    (let ((processes (pipe-processes spec)))
      (if processes
          (loop :for (p . rest) :on processes :do
            (print-process-spec p s) (when rest (princ " | " s)))
          (princ "cat" s)))))

(defmethod print-process-spec ((spec string) &optional s)
  (xcvb-driver::output-string spec s))

(defmethod print-process-spec ((spec cons) &optional s)
  (print-process-spec (parse-process-spec spec) s))

(in-readtable :standard)