;;; macher-agent-test.el --- Comprehensive BDD tests for Macher-Agent -*- lexical-binding: t; -*-

(require 'buttercup)
(require 'macher-agent)
(require 'macher-agent-async)
(require 'macher-agent-context)
(require 'macher-agent-context-tools)
(require 'macher-agent-gptel-tools)
(require 'macher-agent-orchestration)

;; --- Mock structures to satisfy internal requirements ---

(cl-defstruct mock-fsm info)

;; Intercept gptel/macher calls to bypass real LLM and I/O dependencies
(defun gptel-fsm-info (fsm) (mock-fsm-info fsm))
(gv-define-setter gptel-fsm-info (val fsm) `(setf (mock-fsm-info ,fsm) ,val))

(describe "Macher-Agent BDD Test Suite"

          (before-each
           (spy-on 'macher-action)
           (spy-on 'gptel-send)
           (spy-on 'macher--add-termination-handler)
           (setq macher-agent--persistent-context nil)
           (setq macher-agent-active-subagents nil))

          (describe "Asynchronous Logic (macher-agent-async.el)"
                    (it "reports an explicit error when a transition event is 'failed'"
                        (let* ((callback-called nil)
                               (callback (lambda (msg) (setq callback-called msg)))
                               (payload (list :actual-name "test-agent" :callback callback :err "Panic")))
                          (macher-agent--fsm-transition 'any 'error payload)
                          (expect callback-called :to-equal "ERROR: Panic")))

                    (it "detects and handles a killed buffer during polling"
                        (let* ((buf (generate-new-buffer "killed-buf"))
                               (callback-called nil)
                               (callback (lambda (msg) (setq callback-called msg)))
                               (payload (list :buf buf :actual-name "test-agent" :callback callback)))
                          (kill-buffer buf)
                          (macher-agent--fsm-transition 'polling 'check-continuation payload)
                          (expect callback-called :to-equal "ERROR: Buffer 'test-agent' was killed."))))

          (describe "Context & Security (macher-agent-context.el)"
                    (it "throws a security error if accessing a path outside of the allowed context"
                        (let ((ctx (macher--make-context :contents '(("allowed.txt" . ("old" . "new"))))))
                          (expect (macher-agent--ensure-access ctx "forbidden.txt") :to-throw 'error)))

                    (it "successfully records a virtual edit to an existing scoped buffer"
                        (let* ((ctx (macher--make-context :contents '(("test.txt" . ("orig" . "orig"))))))
                          (macher-agent--update-context-file ctx "test.txt" "modified")
                          (expect (macher-context-dirty-p ctx) :to-be t)
                          (expect (cdr (cdr (assoc "test.txt" (macher-context-contents ctx)))) :to-equal "modified")))

                    (describe "Three-way Merge Logic"
                              (it "invalidates the local cache if both local and remote diverged"
                                  (let* ((test-dir (make-temp-file "macher-test-dir" t))
                                         (test-file (expand-file-name "test.txt" test-dir))
                                         (ctx (macher--make-context :dirty-p t)))
                                    
                                    ;; Setup context with a local divergence (v1 -> v2-local)
                                    (setf (macher-context-contents ctx) 
                                          (list (cons test-file (cons "v1" "v2-local"))))
                                    
                                    ;; Setup remote/disk file with a remote divergence (v1 -> v2-remote)
                                    (with-temp-file test-file (insert "v2-remote"))
                                    
                                    ;; Perform sync
                                    (macher-agent--auto-sync-context ctx)
                                    
                                    ;; Expect context to adopt remote state to prevent unsafe conflicts
                                    (let ((pair (cdr (assoc test-file (macher-context-contents ctx)))))
                                      (expect (car pair) :to-equal "v2-remote")
                                      (expect (cdr pair) :to-equal "v2-remote"))
                                    
                                    (delete-directory test-dir t)))))

          (describe "Orchestration Tools (macher-agent-gptel-tools.el)"
                    (it "properly parses a JSON string into a vector for task delegation"
                        (let* ((callback-called nil)
                               (callback (lambda (msg) (setq callback-called msg)))
                               (json-tasks "[{\"buffer_name\": \"test\", \"instructions\": \"do work\"}]")
                               (expected-vector (vector (list :buffer_name "test" :instructions "do work"))))
                          (spy-on 'json-parse-string :and-return-value expected-vector)
                          (let ((parsed (macher-agent--parse-tasks-array json-tasks callback)))
                            (expect (or (vectorp parsed) (listp parsed)) :to-be t)
                            (expect (length parsed) :to-equal 1))))

                    (it "triggers a timeout if sub-agents never update their final result"
                        (let* ((buf (generate-new-buffer "stuck-agent"))
                               (callback-called nil)
                               (callback (lambda (msg) (setq callback-called msg))))
                          (macher-agent--wait-and-return (list buf) callback macher-agent-tool-timeout-attempts nil)
                          (expect callback-called :to-match "ERROR: Buffer 'stuck-agent' failed to start.")
                          (kill-buffer buf)))

                    (it "submit_task_result sets the final result buffer-locally"
                        (let* ((buf (generate-new-buffer "worker-buf"))
                               (tool-fn (gptel-tool-function macher-agent-submit-result-tool)))
                          (with-current-buffer buf
                            ;; Call the extracted LLM tool function directly
                            (funcall tool-fn nil "My final answer")
                            (expect macher-agent--final-result :to-equal "My final answer"))
                          (kill-buffer buf)))
                    
                    (it "write_buffer_in_workspace registers a virtual edit safely"
                        (let* ((ctx (macher--make-context :contents '(("test-buf" . ("orig" . "orig")))))
                               (tool-fn (gptel-tool-function macher-agent-write-buffer-tool))
                               (response (funcall tool-fn ctx "test-buf" "New virtual content")))
                          (expect response :to-match "SUCCESS")
                          (expect (macher-context-dirty-p ctx) :to-be t)
                          (expect (cdr (cdr (assoc "test-buf" (macher-context-contents ctx)))) :to-equal "New virtual content"))))

          (describe "Sandbox Execution (macher-agent-context-tools.el)"
                    (it "constructs a safe rsync command with all necessary exclusions"
                        (let* ((src "/my/project/")
                               (dest "/tmp/sandbox/")
                               (cmd (macher-agent--build-rsync-cmd src dest)))
                          (expect cmd :to-match "^rsync -a")
                          (expect cmd :to-match "--exclude=\\.git/")
                          (expect cmd :to-match "--exclude=node_modules/"))))

          (describe "Interactive Commands & State (macher-agent-orchestration.el)"
                    (it "macher-agent-add-subagent creates a buffer and tracks it globally"
                        (let ((buf (macher-agent-add-subagent "test-worker" "/tmp/")))
                          (expect (buffer-live-p buf) :to-be t)
                          ;; Check if the global state tracking updated
                          (expect (assoc "test-worker" macher-agent-active-subagents) :to-be-truthy)
                          (kill-buffer buf)))

                    (it "macher-agent-apply-virtual-buffers applies pending context edits to live Emacs buffers"
                        (let* ((buf (generate-new-buffer "live-target"))
                               (ctx (macher--make-context :contents (list (cons (buffer-name buf) (cons "old" "new text"))))))
                          (with-current-buffer buf (insert "old"))
                          
                          ;; Set up the environment to pretend we just finished an LLM turn
                          (setq macher--fsm-latest (make-mock-fsm))
                          (spy-on 'macher-agent--fsm-get-context :and-return-value ctx)
                          (spy-on 'macher-agent--auto-sync-context) ;; Don't actually sync in the test
                          
                          (macher-agent-apply-virtual-buffers)
                          
                          (with-current-buffer buf
                            (expect (buffer-string) :to-equal "new text"))
                          (kill-buffer buf)))

                    (it "clears persistent context and latest FSM upon user request"
                        (let ((buf (generate-new-buffer "active-session")))
                          (with-current-buffer buf
                            (setq-local macher-agent--persistent-context 'some-data)
                            (setq-local macher--fsm-latest 'some-fsm)
                            (macher-agent-clear-context)
                            (expect macher-agent--persistent-context :to-be nil)
                            (expect macher--fsm-latest :to-be nil))
                          (kill-buffer buf))))
          )

(provide 'macher-agent-test)
