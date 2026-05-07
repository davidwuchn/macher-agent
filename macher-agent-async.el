;;; macher-agent-async.el --- Asynchronous state machine handling -*- lexical-binding: t; -*-

(require 'macher)

(defun macher-agent-execute-and-wait (action instructions actual-name callback)
  "Trigger an agent ACTION and wait for all tool continuations to finish.
This replaces the need to poll for the FSM."
  (macher-action
   action
   (lambda (err exec fsm)
     (if err
         (funcall callback (format "ERROR: %s" err))
       (let ((buf (macher-action-execution-buffer exec)))
         (macher-agent--track-continuation buf fsm actual-name callback))))
   instructions))

(defun macher-agent--track-continuation (buf fsm actual-name callback)
  "Wait 0.5s to see if a new FSM spawned. If so, track it; otherwise, finish."
  (run-at-time 0.5 nil
               (lambda ()
                 (if (not (buffer-live-p buf))
                     (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
                   (let ((new-fsm (buffer-local-value 'macher--fsm-latest buf)))
                     (if (and new-fsm (not (eq new-fsm fsm)))
                         ;; A continuation happened! Hook into the new FSM's termination.
                         (macher--add-termination-handler
                          new-fsm
                          (lambda (terminated-fsm)
                            (macher-agent--track-continuation buf terminated-fsm actual-name callback)))
                       ;; No continuation occurred. The agent is truly finished.
                       (funcall callback (format "SUCCESS: Sub-agent '%s' completely finished its tasks." actual-name))))))))

(provide 'macher-agent-async)
;;; macher-agent-async.el ends here
