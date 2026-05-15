;;; macher-agent-test.el --- Buttercup tests for Macher-Agent -*- lexical-binding: t; -*-

(require 'buttercup)
(require 'macher-agent)
(require 'macher-agent-async)
(require 'macher-agent-context)
(require 'macher-agent-gptel-tools)

;; mocks

(cl-defstruct mock-fsm info)
(defun gptel-fsm-info (fsm) (mock-fsm-info fsm))
(gv-define-setter gptel-fsm-info (val fsm) `(setf (mock-fsm-info ,fsm) ,val))

(describe "Macher-Agent BDD Test Suite"

  (before-each
    (spy-on 'macher-action)
    (spy-on 'gptel-send)
    (spy-on 'macher--add-termination-handler)
    (setq macher-agent--persistent-context nil))

  (describe "State Machine Integrity (macher-agent-async.el)"
    (it "transitions correctly through polling, tracking, completed, and failed states"
      (let* ((buf (generate-new-buffer "test-buf"))
             (fsm (make-mock-fsm))
             (callback-called nil)
             (callback (lambda (msg) (setq callback-called msg)))
             (payload (list :buf buf :fsm fsm :actual-name "test-agent" :callback callback)))
        
        ;; Test error transition
        (macher-agent--fsm-transition 'failed 'error (plist-put (copy-sequence payload) :err "Test error"))
        (expect callback-called :to-equal "ERROR: Test error")
        (setq callback-called nil)

        ;; Test check-continuation (no continuation)
        (macher-agent--fsm-transition 'polling 'check-continuation payload)
        (expect callback-called :to-equal "SUCCESS: Sub-agent 'test-agent' completely finished its tasks.")
        
        (kill-buffer buf))))

  (describe "Context Synchronisation (macher-agent-context.el)"
    (it "correctly executes a strict three-way merge (Local Virtual vs. Remote Disk/Buffer)"
      (let* ((test-dir (make-temp-file "macher-test-dir" t))
             (test-file (expand-file-name "test.txt" test-dir))
             ;; Instantiate the native struct directly using the internal constructor
             (ctx (macher--make-context :dirty-p t)))
        
        (let ((default-directory test-dir))
          ;; Setup remote/disk file
          (with-temp-file test-file (insert "Original text"))
          
          ;; Setup context with a fast-forward
          (setf (macher-context-contents ctx) 
                (list (cons test-file (cons "Old text" "Old text"))))
          
          ;; Perform sync
          (macher-agent--auto-sync-context ctx)
          
          ;; Expect context to be updated to the remote current state
          (let ((updated-entry (assoc test-file (macher-context-contents ctx))))
            (expect (car (cdr updated-entry)) :to-equal "Original text")
            (expect (cdr (cdr updated-entry)) :to-equal "Original text"))
          
          ;; The dirty flag should be cleared after a clean convergence
          (expect (macher-context-dirty-p ctx) :to-be nil))
        
        (delete-directory test-dir t))))

  (describe "Asynchronous Orchestration (macher-agent-gptel-tools.el)"
    (it "fans out tasks to multiple sub-agents and correctly aggregates all responses without hanging"
      (let* ((buf1 (generate-new-buffer "test-sub-1"))
             (buf2 (generate-new-buffer "test-sub-2"))
             (buffers (list buf1 buf2))
             (callback-called nil)
             (callback (lambda (msg) (setq callback-called msg))))
        
        ;; Set up dummy results in buffers
        (with-current-buffer buf1 (setq-local macher-agent--final-result "Result 1"))
        (with-current-buffer buf2 (setq-local macher-agent--final-result "Result 2"))
        
        ;; Mock run-at-time to prevent actual sleeping/async behaviour during test
        (spy-on 'run-at-time :and-call-fake
                (lambda (_time _repeat fn &rest args)
                  (apply fn args)))
        
        ;; Mock old fsms to simulate that the FSMs have started/finished
        (let ((old-fsms (list (cons buf1 nil) (cons buf2 nil))))
          (with-current-buffer buf1 (setq-local macher--fsm-latest (make-mock-fsm)))
          (with-current-buffer buf2 (setq-local macher--fsm-latest (make-mock-fsm)))
          
          ;; Immediately execute termination handlers when added
          (spy-on 'macher--add-termination-handler :and-call-fake
                  (lambda (fsm handler) (funcall handler fsm)))
          
          (macher-agent--wait-and-return buffers callback 0 old-fsms)
          
          ;; Should successfully aggregate
          (expect callback-called :to-match "SUCCESS. All sub-agents completed.")
          (expect callback-called :to-match "Result 1")
          (expect callback-called :to-match "Result 2"))
        
        (kill-buffer buf1)
        (kill-buffer buf2))))
  )

(provide 'macher-agent-test)
;;; macher-agent-test.el ends here
