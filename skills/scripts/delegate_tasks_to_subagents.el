(require 'macher-agent)

(macher-agent-define-tool macher-agent-delegate-tasks-to-subagents-tool
                          ("Delegate tasks to multiple sub-agents asynchronously, assigning them a specific predefined role." "orchestrate"
                           :args '((:name "tasks" :type array :description "An array of task objects to delegate to sub-agents."
                                          :items (:type object
                                                        :properties (:buffer_name (:type string :description "The exact name of the target sub-agent buffer.")
                                                                                  :instructions (:type string :description "The task instructions for this sub-agent to execute."))
                                                        :required ["buffer_name" "instructions"]))
                                   (:name "preset_name" :type string :description "The EXACT ID of the predefined preset to use (e.g., '@macher-agent-worker', 'programming'). DO NOT use free text.")) 
                           :async t)
                          (tasks preset_name)
                          (let* ((ctx (macher-agent-current-context))
                                 (buffers nil)
                                 (preset-sym (intern (string-trim preset_name)))
                                 (base-preset (alist-get preset-sym gptel-directives)))
                            
                            (unless base-preset
                              (error "INVALID PRESET: '%s' does not exist. You must provide a valid preset ID." preset_name))
                            
                            (let ((final-directive (concat base-preset 
                                                           "\n\n@macher-agent-worker\n=== SYSTEM REMINDER ===\n"
                                                           "You MUST use the `submit_task_result` tool to return your answer. "
                                                           "Do not just type it as plain text.\n")))
                              
                              (cl-loop for task across tasks
                                       for buf-name = (plist-get task :buffer_name)
                                       for instructions = (plist-get task :instructions)
                                       for buf = (get-buffer buf-name)
                                       do (if (buffer-live-p buf)
                                              (with-current-buffer buf
                                                (push buf buffers)
                                                ;; Set the validated preset natively for the upcoming async gptel-send
                                                (setq-local gptel--system-message final-directive)
                                                (macher-agent--prepare-subagent-instructions buf instructions))
                                            (error "Sub-agent buffer '%s' not found. You must spawn it first." buf-name)))
                              
                              (macher-agent--execute-parallel (nreverse buffers) callback))))
