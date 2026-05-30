(macher-agent-make-tool macher-agent-delegate-tasks-to-subagents-tool
                          ("Delegate tasks to multiple sub-agents asynchronously." "orchestrate"
                           :args '((:name "tasks" :type array :description "An array of task objects to delegate to sub-agents."
                                          :items (:type object
                                                        :properties (
                                                                     :buffer_name (:type string :description "The exact name of the target sub-agent buffer.")
                                                                     :instructions (:type string :description "The task instructions for this sub-agent to execute.")
                                                                     :preset (:type string :description "MUST ALWAYS BE exactly '@macher-agent-worker'."))
                                                        :required ["preset" "buffer_name" "instructions"]))) 
                           :async t)
                          (tasks)
                          (let ((ctx (macher-agent-current-context))
                                (buffers nil))
                            
                            (cl-loop for task across tasks
                                     for buf-name = (plist-get task :buffer_name)
                                     for instructions = (plist-get task :instructions)
                                     for preset = (plist-get task :preset)
                                     for buf = (get-buffer buf-name)
                                     do (if (buffer-live-p buf)
                                            (progn
                                              (push buf buffers)
                                              ;; Pass the instructions AND the preset to the prep function
                                              (macher-agent-prepare-instructions buf instructions preset))
                                          (error "Sub-agent buffer '%s' not found. You must spawn it first." buf-name)))
                            
                            (if (null buffers)
                                (funcall callback (list :status 'error :error "ERROR: The 'tasks' array was empty."))
                              (macher-agent-execute-parallel (nreverse buffers) callback))))
