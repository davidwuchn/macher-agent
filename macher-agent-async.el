;;; macher-agent-async.el --- Asynchronous state machine handling -*- lexical-binding: t; -*-

(defvar-local macher-agent--gptel-finished nil
  "Flag to indicate standard gptel finished its current stream.")

(defun macher-agent--gptel-finished-hook (&rest _)
  "Hook to mark gptel request as finished."
  (setq macher-agent--gptel-finished t))

(defun macher-agent--wait-for-completion (buf callback actual-name fsm)
  "Wait for FSM to complete, tracking auto-continuations gracefully."
  (macher--add-termination-handler
   fsm
   (lambda (_)
     (run-at-time 0.5 nil
                  (lambda ()
                    (if (not (buffer-live-p buf))
                        (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
                      (let ((current-fsm (buffer-local-value 'macher--fsm-latest buf)))
                        (if (and current-fsm (not (eq current-fsm fsm)))
                            (macher-agent--wait-for-completion buf callback actual-name current-fsm)
                          (funcall callback (format "SUCCESS: Sub-agent '%s' completely finished its tasks." actual-name))))))))))

(defun macher-agent--catch-fsm-and-wait (buf callback actual-name attempts)
  "Poll until macher initializes the FSM OR standard gptel finishes generating."
  (if (not (buffer-live-p buf))
      (funcall callback (format "ERROR: Buffer '%s' was killed." actual-name))
    (let ((fsm (buffer-local-value 'macher--fsm-latest buf))
          (finished (buffer-local-value 'macher-agent--gptel-finished buf)))
      (cond
       (fsm (macher-agent--wait-for-completion buf callback actual-name fsm))
       (finished
        (run-at-time 0.5 nil
                     (lambda ()
                       (if (not (buffer-live-p buf))
                           (funcall callback (format "ERROR: Buffer '%s' killed." actual-name))
                         (let ((new-fsm (buffer-local-value 'macher--fsm-latest buf)))
                           (if new-fsm
                               (macher-agent--wait-for-completion buf callback actual-name new-fsm)
                             (funcall callback (format "SUCCESS: Sub-agent '%s' completely finished its tasks." actual-name))))))))
       (t
        (if (> attempts 1200)
            (funcall callback "ERROR: Sub-agent execution timed out (took longer than 2 minutes to respond).")
          (run-at-time 0.1 nil (lambda () (macher-agent--catch-fsm-and-wait buf callback actual-name (1+ attempts))))))))))

(provide 'macher-agent-async)
;;; macher-agent-async.el ends here
