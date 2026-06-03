(macher-agent-make-tool macher-agent-delegate-tasks-to-subagents-tool
                        "Delegate tasks to multiple sub-agents asynchronously."
                        :category "orchestrate"
                        :args '((:name "tasks" :type array :description "An array of task objects to delegate to sub-agents."
                                       :items (:type object
                                                     :properties (:buffer_name (:type string)
                                                                               :instructions (:type string)
                                                                               :preset (:type string))
                                                     :required ["preset" "buffer_name" "instructions"])))
                        :command-fn (lambda (payload)
                                      (let* ((raw-tasks (plist-get payload :tasks))
                                             ;; Flatten any vector/list of plists/alists cleanly
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
                                                                                       "@macher-agent-worker")))))
                                        (cons :delegate (vconcat normalized-tasks))))
                        :success-fn (lambda (results)
                                      (let ((output (list "All sub-agents completed. Outputs:\n")))
                                        (cl-loop for res across (if (vectorp results) results (vconcat results))
                                                 do (push (format "=== Response from %s ===\n%s\n" 
                                                                  (plist-get res :buffer_name)
                                                                  (if (eq (plist-get res :status) 'success)
                                                                      (plist-get res :data)
                                                                    (plist-get res :error)))
                                                          output))
                                        (string-join (nreverse output) "\n"))))
