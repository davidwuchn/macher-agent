(macher-agent-make-tool macher-agent-submit-task-result-tool
                        "Submit your final, completed answer back to the parent agent. Call this ONLY when your task is completely finished."
                        :category "worker"
                        :args '((:name "final_answer" :type string :description "The comprehensive final response to the requested task."))
                        :command-fn (lambda (payload _context _root)
                                      (let ((final_answer (plist-get payload :final_answer)))
                                        (macher-agent-submit-task-result final_answer)
                                        (cons :lisp-result "SUCCESS: Result submitted successfully. You have completed your task."))))
