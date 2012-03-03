#+xcvb (module (:depends-on ("macros" "process-spec")))

(in-package :inferior-shell)

(defun run-program/interactively (command &key ignore-error-status)
  ;; force-shell wait
  (let ((return-code
         #+sbcl
          (sb-ext:process-exit-code
           (sb-ext:process-wait
            (sb-ext:run-program
             (car command) (cdr command)
             :search t :input t :output t :error t :wait t)))
          #-sbcl (NIY 'rp/fse)))
    (unless (or ignore-error-status (zerop return-code))
      (cerror "ignore error code~*~*"
              "Process ~S exited with error code ~D"
              command return-code))
    (zerop return-code)))

(defun run-program/ (command &key ignore-error-status output)
  (check-type command cons)
  (funcall (ecase output
             ((nil) 'run-program/for-side-effects)
             ((string :string) 'run-program/read-output-string)
             ((:lines) 'run-program/read-output-lines)
             ((:interactive) 'run-program/interactively)
             ((:form) 'run-program/read-output-form)
             ((:forms) 'run-program/read-output-forms))
           command
           :ignore-error-status ignore-error-status))

(defun run-shell-command (command &rest keys &key ignore-error-status output)
  (declare (ignore ignore-error-status output))
  (check-type command string)
  (apply 'run-program/ (list "/bin/sh" "-c" command) keys))

(defun on-host-spec (host spec)
  (if (current-host-name-p host)
      spec
      `(ssh ,host ,(print-process-spec spec))))

(defun run-process-spec (spec &rest keys &key ignore-error-status output host)
  (declare (ignore ignore-error-status output))
  (etypecase host
    (null
     (etypecase spec
       (string
        (apply 'run-shell-command spec keys))
       (cons
        (apply 'run-process-spec (parse-process-spec spec) keys))
       (process-spec
        (let ((rkeys (list :ignore-error-status ignore-error-status
                           :output output)))
          (if (and (typep spec 'command-spec)
                   (null (command-redirections spec)))
              (apply 'run-program/ (command-arguments spec) rkeys)
              (apply 'run-shell-command (print-process-spec spec) rkeys))))))
    (string
     (apply 'run-process-spec (on-host-spec host spec) :host nil keys))
    (function
     (apply 'run-process-spec (funcall host spec) :host nil keys))))

(defun run (cmd &key on-error time output show host)
  (labels ((process-time ()
             (if time (time (process-command)) (process-command)))
           (process-command ()
             (or
              (run-process-spec
               cmd
               :ignore-error-status t :output output :host host)
              (error-behaviour on-error))))
    (when show
      (format *trace-output* "; ~S~%" cmd))
    (process-time)))

(defun run/s (cmd &rest keys &key on-error time show host)
  "run command CMD, return its standard output results as a string."
  (declare (ignore on-error time show host))
  (apply 'run cmd :output 'string keys))

(defun run/ss (cmd &rest keys &key on-error time show host)
  "Like run/s, but strips the line ending off the result string;
very much like `cmd` or $(cmd) at the shell"
  (declare (ignore on-error time show host))
  (stripln (apply 'run/s cmd keys)))

(defun run/lines (cmd &rest keys &key on-error time show host)
  "Like run/s, but return a list of lines rather than one string"
  (declare (ignore on-error time show host))
  (apply 'run cmd :output :lines keys))