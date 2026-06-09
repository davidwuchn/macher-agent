(macher-agent-make-tool macher-agent-execute-subagents-tool
                        "Execute tasks across multiple sub-agents in parallel in a fire-and-forget, non-blocking manner."
                        :category "orchestrate"
                        :args '((:name "tasks" :type array :description "An array of task objects to execute in parallel in the background."
                                       :items (:type object
                                                     :properties (:buffer_name (:type string)
                                                                               :instructions (:type string)
                                                                               :preset (:type string))
                                                     :required ["buffer_name" "instructions"])))
                        :command-fn (lambda (payload)
                                      (let* ((raw-tasks (plist-get payload :tasks))
                                             (normalized-tasks
                                              (cl-loop for task-obj in (append raw-tasks nil)
                                                       collect (list :buffer_name (or (plist-get task-obj :buffer_name)
                                                                                      (alist-get 'buffer_name task-obj)
                                                                                      (alist-get "buffer_name" task-obj nil nil #'equal))
                                                                     :instructions (or (plist-get task-obj :instructions)
                                                                                       (alist-get 'instructions task-obj)
                                                                                       (alist-get "instructions" task-obj nil nil #'equal))
                                                                     :preset       (or (plist-get task-obj :preset)
                                                                                       (alist-get 'preset task-obj)
                                                                                       (alist-get "preset" task-obj nil nil #'equal)
                                                                                       "macher-agent-worker")
                                                                     :background t))))
                                        (dolist (task normalized-tasks)
                                          (macher-agent-spawn-task task (lambda (res) 
                                                                          (message "Background subagent %s task execution completed with status: %s"
                                                                                   (plist-get res :buffer_name)
                                                                                   (plist-get res :status)))))
                                        (make-macher-agent-tool-response
                                         :type 'lisp-result
                                         :payload (format "SUCCESS: Dispatched %d sub-agents in the background. They are executing independently and asynchronously. Your current buffer remains unblocked and you can proceed with other tasks immediately."
                                                          (length normalized-tasks))))))
