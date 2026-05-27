(macher-agent-define-tool macher-agent-delegate-tasks-to-subagents-tool
                          ("Delegate tasks to multiple sub-agents asynchronously." "orchestrate"
                           :args '((:name "tasks" :type array :description "An array of task objects to delegate to sub-agents."
                                          :items (:type object
                                                        :properties (:buffer_name (:type string :description "The exact name of the target sub-agent buffer.")
                                                                                  :instructions (:type string :description "The task instructions for this sub-agent to execute."))
                                                        :required ["buffer_name" "instructions"]))) 
                           :async t)
                          (tasks)
                          (let ((ctx (macher-agent-current-context))
                                (buffers nil))
                            
                            (cl-loop for task across tasks
                                     for buf-name = (plist-get task :buffer_name)
                                     for instructions = (plist-get task :instructions)
                                     for buf = (get-buffer buf-name)
                                     do (if (buffer-live-p buf)
                                            (progn
                                              (push buf buffers)
                                              (macher-agent--prepare-subagent-instructions buf instructions))
                                          (error "Sub-agent buffer '%s' not found. You must spawn it first." buf-name)))
                            
                            (macher-agent--execute-parallel (nreverse buffers) callback)))
