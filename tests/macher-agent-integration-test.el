;;; macher-agent-integration-test.el --- Tests for macher-agent-skills -*- lexical-binding: t -*-
(require 'buttercup)
(require 'macher-agent-macher-bridge)
(require 'macher-agent)

(describe "Macher-Agent Orchestration Integration"
          (before-each
           (spy-on 'macher-agent-current-context :and-return-value
                   (let ((ctx (macher-agent--make-vfs-context :workspace (cons 'agent (make-macher-agent-workspace :project-root "/mock/proj")) :contents nil)))
                     (macher-agent-initialize-skills ctx macher-agent-bundled-skills-directory)
                     ctx))
           ;; 1. Mock the LLM: Intercept gptel-send to act as the AI for the sub-agents
           (spy-on 'gptel-send :and-call-fake
                   (lambda (&rest _)
                     (let ((buf (current-buffer))
                           (name (buffer-name (current-buffer))))
                       ;; When gptel-send is triggered inside a sub-agent buffer,
                       ;; simulate the LLM successfully using the submit_task_result tool
                       (cond
                        ((string-match-p "agent-france" name)
                         (macher-agent-submit-task-result "The capital of France is Paris.")
                         ;; THE FIX: Pass integer buffer positions instead of strings to satisfy gptel's native hooks
                         (run-hook-with-args 'gptel-post-response-functions (point-min) (point-max)))
                        
                        ((string-match-p "agent-spain" name)
                         (macher-agent-submit-task-result "The capital of Spain is Madrid.")
                         (run-hook-with-args 'gptel-post-response-functions (point-min) (point-max)))))))

           ;; 2. Mock timers: Force deferred buffer cleanups to happen synchronously
           (spy-on 'run-at-time :and-call-fake
                   (lambda (_time _repeat fn &rest args)
                     (apply fn args))))

          (it "executes the full workflow: spawn -> delegate -> await responses -> return combined result"
              (let* ((master-buf (get-buffer-create "*orchestrator-test*"))
                     (final-result nil))
                
                (with-current-buffer master-buf
                  
                  ;; --- A. Setup the Master Orchestrator Context ---
                  ;; We bind the dynamic flag to allow lazy initialisation, perfectly mirroring 
                  ;; gptel-send's pre-flight advice.
                  (let ((macher-agent--allow-lazy-init t))
                    (let* ((spawn-tool (or (gethash "spawn_subagent" (macher-agent-workspace-tools-registry (macher-agent--get-context-workspace (macher-agent-current-context))))
                                           (bound-and-true-p macher-agent-spawn-subagent-tool)))
                           (delegate-tool (or (gethash "delegate_tasks_to_subagents" (macher-agent-workspace-tools-registry (macher-agent--get-context-workspace (macher-agent-current-context))))
                                              (bound-and-true-p macher-agent-delegate-tasks-to-subagents-tool))))
                    
                    ;; --- B. Spawn Sub-agents via Tool ---
                    (let ((spawn-fn (gptel-tool-function spawn-tool)))
                      ;; Safely invoke the tool whether it is flagged as :async t or not
                      (if (gptel-tool-async spawn-tool)
                          (progn
                            (funcall spawn-fn "agent-france" (lambda (res) (setq final-result (cons 'spawn1 res))))
                            (funcall spawn-fn "agent-spain" (lambda (res) (setq final-result (cons 'spawn2 res)))))
                        (funcall spawn-fn "agent-france")
                        (funcall spawn-fn "agent-spain")))

                    (unless (buffer-live-p (get-buffer "*macher-agent: agent-france*"))
                      (error "SPAWN FAILED! final-result=%S spawn-tool=%S" final-result spawn-tool))
                    
                    (expect (buffer-live-p (get-buffer "*macher-agent: agent-france*")) :to-be t)
                    (expect (buffer-live-p (get-buffer "*macher-agent: agent-spain*")) :to-be t)

                    ;; --- C. Delegate Tasks via Tool ---
                    (let ((tasks (vector
                                  (list :buffer_name "*macher-agent: agent-france*"
                                        :instructions "What is the capital of France?"
                                        :preset "@macher-agent-worker")
                                  (list :buffer_name "*macher-agent: agent-spain*"
                                        :instructions "What is the capital of Spain?"
                                        :preset "@macher-agent-worker")))
                          (delegate-fn (gptel-tool-function delegate-tool)))
                      
                      ;; Execute the async delegation tool
                      (funcall delegate-fn
                               tasks
                               (lambda (result)
                                 (setq final-result result))))

                    ;; --- D. Assertions ---
                    
                    ;; 1. The result should be captured synchronously because of our mocks
                    (expect final-result :to-be-truthy)
                    
                    ;; 2. It should contain the beautifully formatted outputs from BOTH sub-agents
                    (expect final-result :to-match "=== Response from \\*macher-agent: agent-france\\* ===")
                    (expect final-result :to-match "The capital of France is Paris.")
                    
                    (expect final-result :to-match "=== Response from \\*macher-agent: agent-spain\\* ===")
                    (expect final-result :to-match "The capital of Spain is Madrid.")
                    
                    ;; 3. The orchestrator hook should have cleanly destroyed the worker buffers
                    (expect (buffer-live-p (get-buffer "*macher-agent: agent-france*")) :to-be nil)
                    (expect (buffer-live-p (get-buffer "*macher-agent: agent-spain*")) :to-be nil)))))))
