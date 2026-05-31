;;; macher-agent-test.el --- Comprehensive BDD tests for Macher-Agent -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'buttercup)
(require 'macher-agent)
(require 'macher-agent-vfs-client)
(require 'macher-agent-gptel-tools)
(require 'macher-agent-orchestration)


(describe "Macher-Agent BDD Test Suite"

          (before-each
           (spy-on 'macher-action)
           (spy-on 'gptel-send)
           (spy-on 'macher--add-termination-handler)
           (setq macher-agent--persistent-context nil)
           (setq macher-agent-active-subagents nil))

          (describe "Context & Security (macher-agent-vfs-client.el)"
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

                              (it "preserves unapplied virtual edits across tool calls if the physical state has not mutated"
                                  (let* ((content-pair (cons "original state" "proposed ghost state"))
                                         (entry (cons "test-file.el" content-pair)))
                                    
                                    ;; Mock the disk returning the exact same original state
                                    (spy-on 'macher-agent--read-content-from-disk-or-buffer :and-return-value "original state")
                                    
                                    (macher-agent--sync-context-entry entry)
                                    
                                    ;; The agent's unapplied virtual edit MUST survive!
                                    (expect (cddr entry) :to-equal "proposed ghost state")))

                              (it "invalidates edits and prevents ghost diffs if the underlying buffer or file is destroyed"
                                  (let* ((content-pair (cons "original state" "proposed ghost state"))
                                         (entry (cons "test-file.el" content-pair)))
                                    
                                    ;; Mock the buffer being killed or file being deleted (returns nil)
                                    (spy-on 'macher-agent--read-content-from-disk-or-buffer :and-return-value nil)
                                    
                                    (macher-agent--sync-context-entry entry)
                                    
                                    ;; The concurrency control detects the change and wipes the ghost edits
                                    (expect (cadr entry) :to-be nil)
                                    (expect (cddr entry) :to-be nil))))

                    (it "splits pure buffers from physical files for independent diff generation"
                        (let* ((ctx (macher--make-context))
                               (file-path (expand-file-name "dummy-file.txt" temporary-file-directory))
                               (pure-name "*macher-dummy-buf*")
                               (file-buf (find-file-noselect file-path))
                               (pure-buf (get-buffer-create pure-name)))
                          
                          ;; 1. Add one physical file and one pure buffer to the context
                          (push (cons file-path (cons "a" "b")) (macher-context-contents ctx))
                          (push (cons pure-name (cons "x" "y")) (macher-context-contents ctx))
                          (expect (length (macher-context-contents ctx)) :to-equal 2)
                          
                          ;; 2. Run the splitter
                          (let* ((split (macher-agent--split-context ctx))
                                 (file-ctx (car split))
                                 (buf-ctx (cdr split)))
                            
                            ;; 3. Verify physical files went to the left (car)
                            (expect (length (macher-context-contents file-ctx)) :to-equal 1)
                            (expect (assoc file-path (macher-context-contents file-ctx)) :to-be-truthy)
                            (expect (assoc pure-name (macher-context-contents file-ctx)) :to-be nil)
                            
                            ;; 4. Verify pure buffers went to the right (cdr)
                            (expect (assoc pure-name (macher-context-contents buf-ctx)) :to-be-truthy)
                            (expect (assoc file-path (macher-context-contents buf-ctx)) :to-be nil))
                          
                          (kill-buffer file-buf)
                          (kill-buffer pure-buf)))

                    (it "triggers the UI safely on completion without modifying the FSM"
                        (let* ((buf (generate-new-buffer "test-bridge"))
                               (ctx (macher--make-context :dirty-p t))
                               (file-path (expand-file-name "test.txt")))
                          (push (cons file-path (cons "old" "new")) (macher-context-contents ctx))
                          
                          (with-current-buffer buf
                            (setq-local macher-agent--is-workspace t)
                            (setq-local macher-agent--persistent-context ctx))
                          
                          (spy-on 'macher--build-patch)
                          
                          ;; Run our clean Post-Response hook
                          (with-current-buffer buf
                            (macher-agent--gptel-post-response-hook nil nil))
                          
                          ;; Verify macher--build-patch was called for the file edits
                          (expect 'macher--build-patch :to-have-been-called)
                          
                          ;; Reset spy
                          (spy-on 'macher--build-patch)
                          
                          ;; When a subagent, it should NOT call macher--build-patch
                          (with-current-buffer buf
                            (setq macher-agent--is-subagent t)
                            (macher-agent--gptel-post-response-hook nil nil))
                          (expect 'macher--build-patch :not :to-have-been-called)
                          (kill-buffer buf))))
          (describe "Macher-Agent Skill Model Selection"

                    (before-each
                     ;; Clear the skills alist to ensure a clean state for each test
                     (setq macher-agent-skills-alist nil))

                    (it "applies the correct model from the skill metadata to gptel-model"
                        (let* ((skill-name 'rust-skill)
                               ;; Register a skill with a specific model
                               (skill-data '(:description "Test" :model gpt-4o :has-tools nil :context-dir nil :body "test"))
                               (execution (macher--make-action-execution :action skill-name)))
                          
                          (setf (alist-get skill-name macher-agent-skills-alist) skill-data)
                          
                          ;; Execute the advice
                          (with-temp-buffer
                            (macher-agent--apply-skill-model-advice execution)
                            
                            ;; Assert that the local variable was set to the model from the metadata
                            (expect gptel-model :to-equal 'gpt-4o))))

                    (it "does not change gptel-model if no model is specified in the skill"
                        (let* ((skill-name 'plain-skill)
                               ;; Register a skill with NO model
                               (skill-data '(:description "Test" :model nil :has-tools nil :context-dir nil :body "test"))
                               (execution (macher--make-action-execution :action skill-name))
                               (original-model gptel-model))
                          
                          (setf (alist-get skill-name macher-agent-skills-alist) skill-data)
                          
                          (with-temp-buffer
                            (setq-local gptel-model original-model)
                            (macher-agent--apply-skill-model-advice execution)
                            
                            ;; Assert that the model remains unchanged
                            (expect gptel-model :to-equal original-model)))))
          (describe "Virtual File System (VFS) Concurrency Control"
                    
                    (describe "macher-agent--sync-context-entry"
                              
                              (it "preserves unapplied virtual edits if the physical disk has NOT mutated"
                                  (let* ((content-pair (cons "original state" "agent edit"))
                                         (entry (cons "test.el" content-pair)))
                                    
                                    ;; Mock the disk returning the exact same original state
                                    (spy-on 'macher-agent--read-content-from-disk-or-buffer :and-return-value "original state")
                                    
                                    (let ((mutated (macher-agent--sync-context-entry entry)))
                                      (expect mutated :to-be nil)
                                      (expect (cadr entry) :to-equal "original state")
                                      (expect (cddr entry) :to-equal "agent edit"))))

                              (it "fast-forwards a clean virtual memory if the physical disk mutates naturally"
                                  (let* ((content-pair (cons "original state" "original state"))
                                         (entry (cons "test.el" content-pair)))
                                    
                                    ;; Mock a physical edit happening while the agent had NO pending edits
                                    (spy-on 'macher-agent--read-content-from-disk-or-buffer :and-return-value "new physical state")
                                    
                                    (let ((mutated (macher-agent--sync-context-entry entry)))
                                      (expect mutated :to-be t)
                                      (expect (cadr entry) :to-equal "new physical state")
                                      (expect (cddr entry) :to-equal "new physical state"))))

                              (it "OPTIMISTIC CONCURRENCY: invalidates virtual edits if a hostile physical mutation occurs"
                                  (let* ((content-pair (cons "original state" "agent edit"))
                                         (entry (cons "test.el" content-pair)))
                                    
                                    ;; Mock the user manually editing the file while the agent was thinking
                                    (spy-on 'macher-agent--read-content-from-disk-or-buffer :and-return-value "user physical edit")
                                    
                                    (let ((mutated (macher-agent--sync-context-entry entry)))
                                      ;; The system MUST detect the conflict and aggressively drop the agent's delta
                                      (expect mutated :to-be t)
                                      (expect (cadr entry) :to-equal "user physical edit")
                                      (expect (cddr entry) :to-equal "user physical edit"))))

                              (it "JIT FLUSH BYPASS: preserves virtual edits if the physical mutation perfectly matches the virtual delta"
                                  (let* ((content-pair (cons "original state" "agent edit"))
                                         (entry (cons "test.el" content-pair)))
                                    
                                    ;; Mock the state immediately after `macher-agent--flush-vfs-to-disk` runs.
                                    ;; The disk now matches the agent's unapplied edit perfectly.
                                    (spy-on 'macher-agent--read-content-from-disk-or-buffer :and-return-value "agent edit")
                                    
                                    (let ((mutated (macher-agent--sync-context-entry entry)))
                                      ;; The system MUST recognise this is its own flush, not a hostile edit!
                                      ;; It returns nil (no conflict) and keeps the original baseline intact for the final diff.
                                      (expect mutated :to-be nil)
                                      (expect (cadr entry) :to-equal "original state")
                                      (expect (cddr entry) :to-equal "agent edit")))))

                    )
          (describe "Macher-Agent Tool Registry Resilience"
                    
                    (it "ensures custom tools survive the preset purge and retain correct category"
                        (let* (;; 1. Define a tool mimicking your agent tools
                               (custom-tool (gptel-make-tool 
                                             :name "cargo_check_tool" 
                                             :function #'ignore 
                                             :category "macher-agent-rust" 
                                             :description "Test tool" 
                                             :args nil))
                               ;; 2. Simulate the clearing function used by presets like macher-ro
                               (clear-fn (plist-get (plist-get macher--preset-clear-tools :tools) :function))
                               ;; 3. Simulate a scenario where a preset attempts to purge everything but 'macher' category tools
                               (tools-list (list custom-tool 
                                                 (gptel-make-tool :name "native_tool" :function #'ignore :category "macher" :description "native" :args nil)))
                               (filtered-tools (funcall clear-fn tools-list)))
                          
                          ;; PROOF: The custom tool MUST survive because it does not match the 'macher' category purge
                          (expect (seq-find (lambda (tool) (string= (gptel-tool-name tool) "cargo_check_tool")) filtered-tools) :not :to-be nil)
                          (expect (gptel-tool-category custom-tool) :to-equal "macher-agent-rust")))

                    (it "verifies that tools identified as 'macher' category get context injected"
                        (let* ((mock-fsm (gptel-make-fsm))
                               (mock-tool (gptel-make-tool :name "test_tool" 
                                                           :function (lambda (ctx) ctx) 
                                                           :category "macher" 
                                                           :description "test" :args nil))
                               (mock-context 'injected-context))
                          
                          (setf (gptel-fsm-info mock-fsm) (list :tools (list mock-tool) :buffer (current-buffer)))
                          
                          ;; Run the macher setup logic
                          (macher--setup-tools mock-fsm (lambda () mock-context))
                          
                          (let* ((processed-tools (plist-get (gptel-fsm-info mock-fsm) :tools))
                                 (processed-tool (car processed-tools)))
                            
                            ;; PROOF: The tool has been wrapped and is now expecting the context
                            (expect (funcall (gptel-tool-function processed-tool)) :to-equal 'injected-context)))))
          (describe "Sandbox Execution (macher-agent-vfs-client.el)"
                    (describe "read_media_in_workspace"
                              (it "errors if gptel-track-media is nil"
                                  (let* ((gptel-track-media nil)
                                         (ctx (macher--make-context :contents '(("test.png" . ("" . "img-data")))))
                                         (tool-fn (gptel-tool-function macher-agent-read-media-in-workspace-tool)))
                                    (spy-on 'macher-agent-current-context :and-return-value ctx)
                                    (let ((result (funcall tool-fn "test.png")))
                                      (expect result :to-match "gptel media send option is off"))))
                              (it "permits access to valid media files inside the workspace without triggering VFS text security locks"
                                  (let* ((gptel-track-media t)
                                         (session (make-macher-agent-session :id "test"))
                                         (macher--fsm-latest 'mock-fsm)
                                         (mock-info (list :macher-agent-session session))
                                         (ctx (macher--make-context :contents nil))
                                         (tool-fn (gptel-tool-function macher-agent-read-media-in-workspace-tool)))
                                    (spy-on 'gptel-fsm-info :and-return-value mock-info)
                                    (spy-on 'macher-agent-current-context :and-return-value ctx)
                                    (spy-on 'macher-agent-context-classify-entry :and-return-value 'media)
                                    (spy-on 'file-exists-p :and-return-value t)
                                    (spy-on 'mailcap-file-name-to-mime-type :and-return-value "image/png")
                                    (let ((result (funcall tool-fn "test_workspace_image.png")))
                                      (expect result :to-match "SUCCESS: Media 'test_workspace_image.png'"))))
                              (it "throws SECURITY ERROR if the tool attempts to read a file classified as text outside VFS scope"
                                  (let* ((gptel-track-media t)
                                         (ctx (macher--make-context :contents nil))
                                         (tool-fn (gptel-tool-function macher-agent-read-media-in-workspace-tool)))
                                    (spy-on 'macher-agent-current-context :and-return-value ctx)
                                    (spy-on 'macher-agent-context-classify-entry :and-return-value 'file)
                                    (let ((err-msg nil))
                                      (condition-case err
                                          (funcall tool-fn "unauthorized_script.sh")
                                        (error (setq err-msg (error-message-string err))))
                                      (expect err-msg :to-match "SECURITY ERROR"))))
                              (it "stages media in the session pending-media instead of polluting gptel-context"
                                  (let* ((gptel-track-media t)
                                         (gptel-context nil)
                                         (session (make-macher-agent-session :id "test"))
                                         (macher--fsm-latest 'mock-fsm)
                                         (mock-info (list :macher-agent-session session))
                                         (ctx (macher--make-context :contents '(("test.png" . ("" . "img-data")))))
                                         (tool-fn (gptel-tool-function macher-agent-read-media-in-workspace-tool)))
                                    (spy-on 'gptel-fsm-info :and-return-value mock-info)
                                    (spy-on 'macher-agent-current-context :and-return-value ctx)
                                    (spy-on 'mailcap-file-name-to-mime-type :and-return-value "image/png")
                                    (spy-on 'file-exists-p :and-return-value t)
                                    (let ((result (funcall tool-fn "test.png")))
                                      (expect result :to-match "SUCCESS: Media")
                                      (expect gptel-context :to-be nil)
                                      (expect (macher-agent-session-pending-media session) :to-be-truthy))))

                              (it "injects pending media into FSM payload and clears the queue pre-flight"
                                  (let* ((buf (current-buffer))
                                         (mock-backend 'mock-backend)
                                         (mock-data '((:role "system" :content "sys")))
                                         (session (make-macher-agent-session :id "test" :pending-media '(("/test.png" :mime "image/png"))))
                                         (mock-info (list :buffer buf :backend mock-backend :data mock-data :macher-agent-session session))
                                         
                                         ;; We can safely use a mock symbol again!
                                         (mock-fsm 'mock-fsm)
                                         
                                         (orig-called nil)
                                         (orig-fun (lambda (fsm &rest _) (setq orig-called fsm))))
                                    
                                    ;; Spy on the accessor to intercept the dynamic funcall
                                    (spy-on 'gptel-fsm-info :and-return-value mock-info)
                                    (spy-on 'gptel--inject-media)
                                    (spy-on 'gptel--inject-prompt)
                                    
                                    ;; Execute the restored advice
                                    (macher-agent--inject-media-fsm-advice orig-fun mock-fsm)
                                    
                                    ;; Verify injection lifecycle
                                    (expect 'gptel-fsm-info :to-have-been-called-with mock-fsm)
                                    (expect 'gptel--inject-media :to-have-been-called)
                                    (expect 'gptel--inject-prompt :to-have-been-called)
                                    (expect orig-called :to-equal mock-fsm)
                                    (expect (macher-agent-session-pending-media session) :to-be nil))))

                    (describe "rsync command building"
                              
                              (it "constructs a Git-aware piped shell command when inside a Git repo"
                                  ;; Mock Git returning 0 (success - inside a work tree)
                                  (spy-on 'call-process :and-return-value 0)
                                  
                                  (let* ((src "/my/project/")
                                         (dest "/tmp/sandbox/")
                                         (cmd (macher-agent--build-rsync-cmd src dest)))
                                    
                                    ;; It MUST return a single shell string for the pipeline.
                                    ;; We use (stringp ...) instead of :to-be-a
                                    (expect (stringp cmd) :to-be t)
                                    (expect cmd :to-match "git -C .* ls-files")
                                    (expect cmd :to-match "rsync -aLC0 --delete")))

                              (it "falls back to a standard exclusion list when outside a Git repo"
                                  ;; Mock Git returning 128 (error - not a git repository)
                                  (spy-on 'call-process :and-return-value 128)
                                  
                                  (let* ((src "/my/project/")
                                         (dest "/tmp/sandbox/")
                                         (cmd (macher-agent--build-rsync-cmd src dest)))
                                    
                                    ;; It MUST fall back to a safe argument list.
                                    ;; We use (listp ...) instead of :to-be-a
                                    (expect (listp cmd) :to-be t)
                                    (expect (nth 0 cmd) :to-equal "rsync")
                                    (expect (nth 1 cmd) :to-equal "-aLC")
                                    (expect (nth 2 cmd) :to-equal "--delete")
                                    (expect (member "--exclude" cmd) :to-be-truthy)
                                    (expect (member "node_modules/" cmd) :to-be-truthy)))))
          (describe "Macher-Agent Tool Category Isolation"
                    
                    (it "preserves the custom category to avoid being purged by upstream read-only presets"
                        (let ((mock-tool (gptel-make-tool :name "my_custom_tool" 
                                                          :function #'ignore 
                                                          :category "macher-agent-calendar" 
                                                          :description "test" 
                                                          :args nil))
                              ;; Extract the clearing function from the upstream preset definition
                              (clear-fn (plist-get (plist-get macher--preset-clear-tools :tools) :function)))
                          
                          ;; The custom tool MUST maintain its distinct category boundary
                          (expect (gptel-tool-category mock-tool) :not :to-equal macher-tool-category)
                          
                          ;; It MUST survive the upstream framework's aggressive tool purge
                          (let ((filtered-tools (funcall clear-fn (list mock-tool))))
                            (expect (length filtered-tools) :to-equal 1)
                            (expect (gptel-tool-name (car filtered-tools)) :to-equal "my_custom_tool")))))
          (describe "Virtual File System (VFS) Sandbox Isolation"
                    
                    (describe "macher-agent--flush-vfs-to-sandbox"
                              
                              (it "reroutes virtual edits to the ephemeral sandbox, protecting the physical disk"
                                  (let* ((workspace-root "/my/project/")
                                         (sandbox-dir "/tmp/sandbox-12345/")
                                         ;; Create a mock context representing a dirty workspace
                                         (mock-ws (cons 'agent workspace-root))
                                         (mock-ctx (macher--make-context :dirty-p t 
                                                                         :workspace mock-ws
                                                                         :contents '(("/my/project/src/main.rs" . ("orig" . "new content")))))
                                         (write-region-called-with nil))
                                    
                                    ;; Mock the context provider
                                    (spy-on 'macher-agent-current-context :and-return-value mock-ctx)
                                    
                                    ;; Intercept the destructive write action
                                    (spy-on 'write-region :and-call-fake 
                                            (lambda (start _end filename &rest _)
                                              (push (list start filename) write-region-called-with)))
                                    
                                    (macher-agent--flush-vfs-to-sandbox sandbox-dir)
                                    
                                    ;; The orchestrator MUST execute a file write...
                                    (expect 'write-region :to-have-been-called)
                                    
                                    ;; ...it MUST write the new virtual content...
                                    (expect (caar write-region-called-with) :to-equal "new content")
                                    
                                    ;; ...and CRITICALLY, it MUST write it to the sandbox, NOT the physical /my/project/ path!
                                    (expect (cadar write-region-called-with) :to-equal "/tmp/sandbox-12345/src/main.rs")))

                              (it "does not flush anything if the virtual memory is clean"
                                  (let* ((mock-ctx (macher--make-context :dirty-p nil :contents nil)))
                                    
                                    (spy-on 'macher-agent-current-context :and-return-value mock-ctx)
                                    (spy-on 'write-region)
                                    
                                    (macher-agent--flush-vfs-to-sandbox "/tmp/sandbox-12345/")
                                    
                                    ;; Ensure no ghost files are created in the sandbox
                                    (expect 'write-region :not :to-have-been-called)))))
          (describe "Interactive Commands & State (macher-agent-orchestration.el)"
                    (it "macher-agent-add-buffer-to-scope explicitly errors out if no existing session is found"
                        (let ((buf (generate-new-buffer "lazy-target")))
                          (let ((macher--fsm-latest nil)
                                (macher-agent--persistent-context nil))
                            (cl-letf (((symbol-function 'buffer-list) (lambda () nil)))
                              (expect (macher-agent-add-buffer-to-scope "lazy-target") :to-throw 'error)))
                          (kill-buffer buf)))
                    (it "macher-agent-add-subagent creates a buffer and tracks it globally"
                        (let ((buf (macher-agent-add-subagent "test-worker" "/tmp/")))
                          (expect (buffer-live-p buf) :to-be t)
                          (expect (assoc "test-worker" macher-agent-active-subagents) :to-be-truthy)
                          (kill-buffer buf)))

                    (it "macher-agent-apply-virtual-buffers applies pending context edits to live Emacs buffers"
                        (let* ((buf (generate-new-buffer "live-target"))
                               (ctx (macher--make-context :contents (list (cons (buffer-name buf) (cons "old" "new text"))))))
                          (with-current-buffer buf (insert "old"))
                          
                          (spy-on 'macher-agent-current-context :and-return-value ctx)
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
                     (macher-agent-make-tool mock-async-contract-tool
                                             ("Mock async tool" "test" :args '((:name "arg1" :type string) (:name "arg2" :type string)) :async t)
                                             (arg1 arg2)
                                             (funcall gptel-callback (format "Async %s %s" arg1 arg2)))

                     (macher-agent-make-tool mock-sync-contract-tool
                                             ("Mock sync tool" "test" :args '((:name "arg1" :type string)))
                                             (arg1)
                                             (format "Sync %s" arg1)))

                    (it "generates variadic signatures for async tools to safely absorb FSM contexts"
                        (let* ((tool-fn (gptel-tool-function mock-async-contract-tool))
                               (arity (func-arity tool-fn)))
                          ;; A variadic &rest signature always has a minimum of 0 and a maximum of 'many
                          (expect (car arity) :to-equal 0)
                          (expect (cdr arity) :to-equal 'many)))

                    (it "generates variadic signatures for sync tools to safely absorb FSM contexts"
                        (let* ((tool-fn (gptel-tool-function mock-sync-contract-tool))
                               (arity (func-arity tool-fn)))
                          (expect (car arity) :to-equal 0)
                          (expect (cdr arity) :to-equal 'many))))
          
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

                    (it "verifies tool resolution hierarchy (workspace shadows package tools)"
                        (let* ((pkg-dir (make-temp-file "macher-pkg" t))
                               (ws-dir (make-temp-file "macher-ws" t))
                               (pkg-scripts (expand-file-name "scripts" pkg-dir))
                               (ws-scripts (expand-file-name "scripts" ws-dir)))
                          (make-directory pkg-scripts t)
                          (make-directory ws-scripts t)
                          ;; Package provides tool-a and tool-b
                          (with-temp-file (expand-file-name "tool-a.el" pkg-scripts) (insert "(setq tool-a 'pkg-a)"))
                          (with-temp-file (expand-file-name "tool-b.el" pkg-scripts) (insert "(setq tool-b 'pkg-b)"))
                          ;; Workspace overrides tool-a
                          (with-temp-file (expand-file-name "tool-a.el" ws-scripts) (insert "(setq tool-a 'ws-a)"))
                          
                          ;; Clear registry
                          (clrhash macher-agent-tools-registry)
                          
                          ;; Resolve pkg first, then workspace shadows
                          (let* ((res-pkg-b (macher-agent-resolve-tool "tool-b" pkg-dir))
                                 (res-ws-a (macher-agent-resolve-tool "tool-a" ws-dir)))
                            (expect res-pkg-b :to-equal 'pkg-b)
                            (expect res-ws-a :to-equal 'ws-a))
                          
                          (delete-directory pkg-dir t)
                          (delete-directory ws-dir t)))
                    
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
                          (expect (plist-get parsed :body) :to-match "Version: 0.1.0")))

                    (it "creates a preset when allowed-tools is provided"
                        (let* ((mock-dir (make-temp-file "macher-test-skills-preset" t))
                               (skill-dir (expand-file-name "test-skill" mock-dir)))
                          (make-directory skill-dir t)
                          (with-temp-file (expand-file-name "SKILL.md" skill-dir)
                            (insert "---\nname: my-preset\ndescription: test\nallowed-tools: []\nmodel: gpt-4o\n---\nPreset body"))
                          (spy-on 'gptel-make-preset)
                          (let ((gptel-directives nil))
                            (macher-agent-api-register-skills-in-directory mock-dir)
                            (expect 'gptel-make-preset :to-have-been-called)
                            (let ((args (spy-calls-args-for 'gptel-make-preset 0)))
                              (expect (car args) :to-equal 'my-preset)
                              (expect (plist-get (cdr args) :system) :to-equal "Preset body")
                              (expect (plist-get (cdr args) :model) :to-equal 'gpt-4o))
                            (expect (alist-get 'my-preset gptel-directives) :to-equal "Preset body"))
                          (delete-directory mock-dir t)))

                    (it "injects directly into gptel-directives when allowed-tools is omitted"
                        (let* ((mock-dir (make-temp-file "macher-test-skills-directive" t))
                               (skill-dir (expand-file-name "test-skill" mock-dir)))
                          (make-directory skill-dir t)
                          (with-temp-file (expand-file-name "SKILL.md" skill-dir)
                            (insert "---\nname: my-directive\n---\nDirective body"))
                          (let ((gptel-directives nil))
                            (macher-agent-api-register-skills-in-directory mock-dir)
                            (expect (alist-get 'my-directive gptel-directives) :to-equal "Directive body"))
                          (delete-directory mock-dir t)))))

(provide 'macher-agent-test)
