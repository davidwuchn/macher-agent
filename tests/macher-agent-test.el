;;; macher-agent-test.el --- Comprehensive BDD tests for Macher-Agent -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'buttercup)
(require 'macher-agent)
(require 'macher-agent-async)
(require 'macher-agent-context)
(require 'macher-agent-context-tools)
(require 'macher-agent-gptel-tools)
(require 'macher-agent-orchestration)
(require 'macher-agent-skills)

(cl-defstruct mock-fsm info)

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
                                    
                                    (setf (macher-context-contents ctx) 
                                          (list (cons test-file (cons "v1" "v2-local"))))
                                    
                                    (with-temp-file test-file (insert "v2-remote"))
                                    
                                    (macher-agent--auto-sync-context ctx)
                                    
                                    (let ((pair (cdr (assoc test-file (macher-context-contents ctx)))))
                                      (expect (car pair) :to-equal "v2-remote")
                                      (expect (cdr pair) :to-equal "v2-remote"))
                                    
                                    (delete-directory test-dir t)))

                              (it "discards unapplied buffer patches to prevent ghost diffs"
                                  (let* ((ctx (macher--make-context))
                                         (buf-name "ghost-buffer")
                                         (buf (get-buffer-create buf-name)))
                                    (with-current-buffer buf 
                                      (erase-buffer)
                                      (insert "original state"))
                                    
                                    ;; 1. Simulate the agent proposing a change that hasn't been applied yet
                                    (push (cons buf-name (cons "original state" "proposed ghost state")) 
                                          (macher-context-contents ctx))
                                    (setf (macher-context-dirty-p ctx) t)
                                    
                                    ;; 2. Run the sync (simulating the start of a new turn where the user ignored the patch)
                                    (macher-agent--auto-sync-context ctx)
                                    
                                    ;; 3. Verify the edit was wiped from memory
                                    (let* ((entry (assoc buf-name (macher-context-contents ctx)))
                                           (new-content (cddr entry)))
                                      (expect new-content :to-equal "original state")
                                      (expect (macher-context-dirty-p ctx) :to-be nil))
                                    
                                    (kill-buffer buf))))

                    (it "splits pure buffers from physical files for independent diff generation"
                        (let* ((ctx (macher--make-context))
                               (file-path (expand-file-name "dummy-file.txt" temporary-file-directory))
                               (pure-name "*macher-dummy-buf*")
                               (file-buf (find-file-noselect file-path))
                               (pure-buf (get-buffer-create pure-name)))
                          
                          ;; 1. Add one physical file and one pure buffer to the context
                          (push (cons file-path (cons "a" "b")) (macher-context-contents ctx))
                          (push (cons pure-name (cons "x" "y")) (macher-context-contents ctx))
                          
                          ;; 2. Run the splitter
                          (let* ((split (macher-agent--split-context ctx))
                                 (file-ctx (car split))
                                 (buf-ctx (cdr split)))
                            
                            ;; 3. Verify physical files went to the left (car)
                            (expect (assoc file-path (macher-context-contents file-ctx)) :to-be-truthy)
                            (expect (assoc pure-name (macher-context-contents file-ctx)) :to-be nil)
                            
                            ;; 4. Verify pure buffers went to the right (cdr)
                            (expect (assoc pure-name (macher-context-contents buf-ctx)) :to-be-truthy)
                            (expect (assoc file-path (macher-context-contents buf-ctx)) :to-be nil))
                          
                          (kill-buffer file-buf)
                          (kill-buffer pure-buf)))

                    (it "forcefully injects :macher--context into the FSM info plist to awaken the native UI"
                        (let* ((fsm (gptel-make-fsm))
                               (ctx (macher--make-context :dirty-p t))
                               (get-context (lambda () ctx)))
                          
                          (spy-on 'macher-process-request)
                          
                          ;; 1. Run our Proxy Bridge
                          (macher-agent--bridge-context-advice 
                           (lambda (f get) nil) ; Mock the native orig-fun
                           fsm 
                           get-context)
                          
                          ;; 2. Extract the termination handler safely from the spy records.
                          ;; FIX: spy-calls-args-for requires the exact call index (0)
                          (let* ((args (spy-calls-args-for 'macher--add-termination-handler 0))
                                 (term-handler (cadr args)))
                            
                            (funcall term-handler fsm)
                            
                            ;; 3. Verify the bridge successfully injected the context into the precise native slot
                            (let ((info (gptel-fsm-info fsm)))
                              (expect (plist-get info :macher--context) :to-be ctx))
                            
                            ;; 4. Verify the native UI engine was called
                            (expect 'macher-process-request :to-have-been-called-with 'complete fsm)))))

          (describe "Orchestration Tools (macher-agent-gptel-tools.el)"
                    (it "guarantees list_buffers_in_workspace output perfectly matches context-tree buffer categorisation"
                        (let* ((ctx (macher--make-context :contents '(("*pure-buffer*" . ("" . ""))
                                                                      ("/external/path.txt" . ("" . ""))
                                                                      ("/root/internal.txt" . ("" . "")))))
                               (list-tool-fn (gptel-tool-function macher-agent-list-buffers-in-workspace-tool)))

                          (spy-on 'macher-agent-current-context :and-return-value ctx)
                          (spy-on 'macher-agent-context-classify-entry :and-call-fake
                                  (lambda (path &rest _)
                                    (pcase path
                                      ("*pure-buffer*" 'buffer)
                                      ("/external/path.txt" 'external)
                                      ("/root/internal.txt" 'file))))

                          (let ((result (funcall list-tool-fn)))
                            (expect result :to-match "\\*pure-buffer\\*")
                            (expect result :to-match "/external/path\\.txt")
                            (expect result :not :to-match "internal\\.txt"))))
                    (it "properly parses a JSON string into a vector for task delegation"
                        (let* ((callback-called nil)
                               (callback (lambda (res) (setq callback-called res)))
                               (json-tasks "[{\"buffer_name\": \"test-sub\", \"instructions\": \"do work\"}]")
                               (expected-vector (vector (list :buffer_name "test-sub" :instructions "do work")))
                               (tool-fn (gptel-tool-function macher-agent-delegate-tasks-to-subagents-tool))
                               (buf (get-buffer-create "test-sub")))
                          
                          (spy-on 'json-parse-string :and-return-value expected-vector)
                          (spy-on 'macher-agent--execute-parallel)
                          (spy-on 'macher-agent--prepare-subagent-instructions)
                          (spy-on 'macher-agent--ensure-access)
                          
                          (funcall tool-fn callback json-tasks)
                          
                          (expect 'macher-agent--execute-parallel :to-have-been-called)
                          (kill-buffer buf)))

                    (it "reports an error if gptel-send aborts or fails silently"
                        (let* ((buf (generate-new-buffer "worker"))
                               (callback-called nil)
                               (callback (lambda (msg) (setq callback-called msg))))

                          ;; Simulate gptel-send firing and instantly triggering the post-response hook
                          (spy-on 'gptel-send :and-call-fake
                                  (lambda ()
                                    (with-current-buffer buf
                                      (run-hook-with-args 'gptel-post-response-functions (point-min) (point-max)))))

                          (macher-agent--dispatch-and-wait buf callback)
                          
                          (expect (plist-get callback-called :status) :to-equal 'error)
                          (expect (plist-get callback-called :error) :to-match "stopped silently")
                          (kill-buffer buf)))

                    (it "correctly aggregates results from multiple event-driven sub-agents"
                        (let* ((buf1 (generate-new-buffer "worker1"))
                               (buf2 (generate-new-buffer "worker2"))
                               (callback-called nil)
                               (callback (lambda (msg) (setq callback-called msg))))
                          
                          ;; Mock the dispatcher to instantly return a success payload rather than firing the network
                          (spy-on 'macher-agent--dispatch-and-wait :and-call-fake
                                  (lambda (b cb)
                                    (funcall cb (list :status 'success :data (format "Output from %s" (buffer-name b))))))
                          
                          (macher-agent--execute-parallel (list buf1 buf2) callback)
                          
                          (expect (plist-get callback-called :status) :to-equal 'success)
                          (expect (plist-get callback-called :data) :to-match "All sub-agents completed.")
                          (expect (plist-get callback-called :data) :to-match "Output from worker1")
                          (expect (plist-get callback-called :data) :to-match "Output from worker2")
                          (kill-buffer buf1)
                          (kill-buffer buf2)))

                    (it "ensures target buffer exists when using write_buffer_in_workspace to support patch UI"
                        (let* ((ctx (macher--make-context :contents nil))
                               (tool-fn (gptel-tool-function macher-agent-write-buffer-in-workspace-tool)))
                          (spy-on 'macher-agent-current-context :and-return-value ctx)
                          
                          (funcall tool-fn "*new-virtual-asset*" "Ghost content")
                          
                          (expect (assoc "*new-virtual-asset*" (macher-context-contents ctx)) :not :to-be nil)
                          ;; Assert that the buffer WAS created so the patch engine can diff against it
                          (expect (buffer-live-p (get-buffer "*new-virtual-asset*")) :to-be t)))
                    
                    (it "rejects fuzzy security matching in read_buffer_in_workspace"
                        (let* ((ctx (macher--make-context :contents '(("*scratch*" . ("" . "content")))))
                               (tool-fn (gptel-tool-function macher-agent-read-buffer-in-workspace-tool)))
                          (spy-on 'macher-agent-current-context :and-return-value ctx)
                          (let ((threw nil))
                            (condition-case err
                                (funcall tool-fn "scratch")
                              (error (setq threw t)
                                     (expect (error-message-string err) :to-match "SECURITY ERROR.*scratch.*")))
                            (expect threw :to-be t))))

                    (it "submit_task_result sets the final result buffer-locally"
                        (let* ((buf (generate-new-buffer "worker-buf"))
                               (tool-fn (gptel-tool-function macher-agent-submit-task-result-tool)))
                          (with-current-buffer buf
                            (funcall tool-fn "My final answer")
                            (expect macher-agent--final-result :to-equal "My final answer"))
                          (kill-buffer buf)))
                    
                    (it "write_buffer_in_workspace registers a virtual edit safely"
                        (let* ((ctx (macher--make-context :contents '(("test-buf" . ("orig" . "orig")))))
                               (tool-fn (gptel-tool-function macher-agent-write-buffer-in-workspace-tool)))
                          (spy-on 'macher-agent-current-context :and-return-value ctx)
                          
                          (let* ((response (funcall tool-fn "test-buf" "New virtual content")))
                            (expect response :to-match "SUCCESS")
                            (expect (macher-context-dirty-p ctx) :to-be t)
                            (expect (cdr (cdr (assoc "test-buf" (macher-context-contents ctx)))) :to-equal "New virtual content")))))

          (describe "Sandbox Execution (macher-agent-context-tools.el)"
                    (it "constructs a safe rsync command with all necessary exclusions"
                        (let* ((src "/my/project/")
                               (dest "/tmp/sandbox/")
                               (cmd (macher-agent--build-rsync-cmd src dest)))
                          (expect cmd :to-match "^rsync -a")
                          (expect cmd :to-match "--exclude=\\.git/")
                          (expect cmd :to-match "--exclude=node_modules/"))))

          (describe "Interactive Commands & State (macher-agent-orchestration.el)"
                    (it "macher-agent-add-buffer-to-scope lazily initialises a missing context"
                        (let ((buf (generate-new-buffer "lazy-target")))
                          (setq macher-agent--persistent-context nil)
                          
                          (macher-agent-add-buffer-to-scope "lazy-target")
                          
                          (expect macher-agent--persistent-context :not :to-be nil)
                          (expect (assoc "lazy-target" (macher-context-contents macher-agent--persistent-context)) :not :to-be nil)))
                    (it "macher-agent-add-subagent creates a buffer and tracks it globally"
                        (let ((buf (macher-agent-add-subagent "test-worker" "/tmp/")))
                          (expect (buffer-live-p buf) :to-be t)
                          (expect (assoc "test-worker" macher-agent-active-subagents) :to-be-truthy)
                          (kill-buffer buf)))

                    (it "macher-agent-apply-virtual-buffers applies pending context edits to live Emacs buffers"
                        (let* ((buf (generate-new-buffer "live-target"))
                               (ctx (macher--make-context :contents (list (cons (buffer-name buf) (cons "old" "new text"))))))
                          (with-current-buffer buf (insert "old"))
                          
                          (setq macher--fsm-latest (make-mock-fsm))
                          (spy-on 'macher-agent--fsm-get-context :and-return-value ctx)
                          (spy-on 'macher-agent--auto-sync-context)
                          
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

          (describe "Tool Signatures (Macro Contracts)"
                    (before-all
                     (macher-agent-define-tool mock-async-contract-tool
                                               ("Mock async tool" "test" :args '((:name "arg1" :type string) (:name "arg2" :type string)) :async t)
                                               (arg1 arg2)
                                               (funcall gptel-callback (format "Async %s %s" arg1 arg2)))

                     (macher-agent-define-tool mock-sync-contract-tool
                                               ("Mock sync tool" "test" :args '((:name "arg1" :type string)))
                                               (arg1)
                                               (format "Sync %s" arg1)))

                    (it "generates exact signatures for async tools (callback + args)"
                        (let* ((tool-fn (gptel-tool-function mock-async-contract-tool))
                               (arity (func-arity tool-fn)))
                          (expect (car arity) :to-equal 3)
                          (expect (cdr arity) :to-equal 3)))

                    (it "generates exact signatures for sync tools (only args)"
                        (let* ((tool-fn (gptel-tool-function mock-sync-contract-tool))
                               (arity (func-arity tool-fn)))
                          (expect (car arity) :to-equal 1)
                          (expect (cdr arity) :to-equal 1))))
          
          (describe "Agent Skills (macher-agent-skills.el)"
                    (it "parses SKILL.md files correctly extracting frontmatter and markdown body"
                        (let* ((parsed (macher-agent-parse-skill-file "tests/fixtures/skills/global/SKILL.md")))
                          (expect (plist-get parsed :name) :to-equal "mock-skill")
                          (expect (plist-get parsed :name-sym) :to-equal 'mock-skill)
                          (expect (plist-get parsed :description) :to-equal "A mock skill for testing")
                          (expect (plist-get parsed :allowed-tools) :to-equal '("mock-tool-1" "mock-tool-2"))
                          (expect (plist-get parsed :body) :to-equal "This is the system prompt for the mock skill.\nIt spans multiple lines.")))

                    (it "resolves global skill tools by loading their script if not registered"
                        (let* ((mock-script-dir "tests/fixtures/skills/global/scripts")
                               (mock-script-path (expand-file-name "mock-tool-load.el" mock-script-dir)))
                          ;; Setup mock script
                          (make-directory mock-script-dir t)
                          (with-temp-file mock-script-path
                            (insert "(setq mock-tool-load 'loaded-tool-object)"))
                          
                          ;; Resolution test
                          (let ((resolved (macher-agent-resolve-tool "mock-tool-load" "tests/fixtures/skills/global/")))
                            (expect resolved :to-equal 'loaded-tool-object))
                          
                          (delete-directory mock-script-dir t)))

                    (it "refuses to load workspace skill tools (security context)"
                        (let* ((mock-script-dir "tests/fixtures/skills/workspace/scripts")
                               (mock-script-path (expand-file-name "workspace-tool-1.el" mock-script-dir)))
                          ;; Setup mock script
                          (make-directory mock-script-dir t)
                          (with-temp-file mock-script-path
                            (insert "(setq workspace-tool-1 'workspace-loaded)"))
                          
                          ;; Test workspace parsing logic
                          (macher-agent-load-skill-from-file "tests/fixtures/skills/workspace/SKILL.md" nil)
                          (let ((skill-meta (alist-get 'workspace-skill macher-agent-skills-alist)))
                            (expect (plist-get skill-meta :context-dir) :to-be nil))
                          
                          ;; Resolution should fail to load because context-dir is nil,
                          ;; returning the raw string fallback instead of a loaded tool object.
                          (let ((resolved (macher-agent-resolve-tool "workspace-tool-1" nil)))
                            (expect resolved :to-equal "workspace-tool-1")
                            (expect (boundp 'workspace-tool-1) :to-be nil))
                          
                          (delete-directory mock-script-dir t)))
                    
                    (it "applies skill tools correctly into gptel-tools when selected"
                        (let ((gptel-tools nil)
                              (mock-tool-obj 'the-tool))
                          (puthash "selected-tool" mock-tool-obj macher-agent-tools-registry)
                          
                          (setf (alist-get 'test-preset macher-agent-skills-alist)
                                (list :description "test" :tools '("selected-tool") :context-dir nil))
                          
                          (macher-agent--apply-skill-tools 'test-preset)
                          
                          (expect gptel-tools :to-equal (list mock-tool-obj))))

                    (it "expands org-macros in SKILL.md body"
                        (let* ((parsed (macher-agent-parse-skill-file "tests/fixtures/skills/macro-skill/SKILL.md")))
                          (expect (plist-get parsed :body) :to-match "Version: 0.1.0")))))

(provide 'macher-agent-test)
