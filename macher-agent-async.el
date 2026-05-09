;;; macher-agent-async.el --- Asynchronous state machine handling -*- lexical-binding: t; -*-

(require 'macher)

(defun macher-agent--fsm-transition (_state event payload)
  "Explicit FSM transition handler for agent execution tracking.
STATE is the current tracking state, EVENT is the transition trigger,
and PAYLOAD contains context data (buf, fsm, actual-name, callback)."
  (let ((buf (plist-get payload :buf))
        (fsm (plist-get payload :fsm))
        (actual-name (plist-get payload :actual-name))
        (callback (plist-get payload :callback)))
    (pcase event
      ('error
       (let ((err (plist-get payload :err)))
         (funcall callback (format "ERROR: %s" err))))
      
      ('check-continuation
       (if (not (buffer-live-p buf))
           (macher-agent--fsm-transition 'failed 'buffer-killed payload)
         (let ((new-fsm (buffer-local-value 'macher--fsm-latest buf)))
           (if (and new-fsm (not (eq new-fsm fsm)))
               (macher-agent--fsm-transition 'tracking 'continuation-found 
                                             (plist-put payload :new-fsm new-fsm))
             (macher-agent--fsm-transition 'completed 'no-continuation payload)))))
      
      ('buffer-killed
       (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name)))
      
      ('continuation-found
       (let ((new-fsm (plist-get payload :new-fsm)))
         (macher--add-termination-handler
          new-fsm
          (lambda (terminated-fsm)
            (macher-agent--track-continuation buf terminated-fsm actual-name callback)))))
      
      ('no-continuation
       (funcall callback (format "SUCCESS: Sub-agent '%s' completely finished its tasks." actual-name))))))

(defun macher-agent--track-continuation (buf fsm actual-name callback)
  "Wait 0.5s to see if a new FSM spawned. If so, track it; otherwise, finish.
Delegates to the explicit FSM transition handler."
  (run-at-time 0.5 nil
               (lambda ()
                 (macher-agent--fsm-transition 
                  'polling 'check-continuation 
                  (list :buf buf :fsm fsm :actual-name actual-name :callback callback)))))

(defun macher-agent-execute-and-wait (action instructions actual-name callback)
  "Trigger an agent ACTION and wait for all tool continuations to finish.
This replaces the need to poll for the FSM by using explicit transitions."
  (macher-action
   action
   (lambda (err exec fsm)
     (let ((payload (list :actual-name actual-name :callback callback)))
       (if err
           (macher-agent--fsm-transition 'failed 'error (plist-put payload :err err))
         (let ((buf (macher-action-execution-buffer exec)))
           (macher-agent--track-continuation buf fsm actual-name callback)))))
   instructions))

(provide 'macher-agent-async)
;;; macher-agent-async.el ends here
