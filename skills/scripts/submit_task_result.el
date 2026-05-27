(macher-agent-define-tool macher-agent-submit-task-result-tool
                          ("Submit your final, completed answer back to the parent agent. Call this ONLY when your task is completely finished."
                           "worker"
                           :args '((:name "final_answer" :type string :description "The comprehensive final response to the requested task.")))
                          (final_answer)
                          (setq-local macher-agent--final-result final_answer)
                          "SUCCESS: Result submitted successfully. You have completed your task.")
