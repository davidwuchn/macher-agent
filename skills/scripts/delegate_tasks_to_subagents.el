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
                (let ((tasks (plist-get payload :tasks)))
                  (cons :delegate tasks)))
  :success-fn (lambda (results)
                (let ((output (list "All sub-agents completed. Outputs:\n")))
                  (cl-loop for res in results
                           do (push (format "=== Response from %s ===\n%s\n" 
                                            (plist-get res :buffer_name)
                                            (if (eq (plist-get res :status) 'success)
                                                (plist-get res :data)
                                              (plist-get res :error)))
                                    output))
                  (string-join (nreverse output) "\n"))))