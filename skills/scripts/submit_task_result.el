(macher-agent-make-tool macher-agent-submit-task-result-tool
                        ("Submit your final, completed answer back to the parent agent. Call this ONLY when your task is completely finished."
                         "worker"
                         :args '((:name "final_answer" :type string :description "The comprehensive final response to the requested task.")))
                        (final_answer)
                        
                        ;; 1. Register the answer in the buffer-local variable
                        (macher-agent-submit-task-result final_answer)
                        
                        ;; 2. Return a string so gptel can gracefully finish the tool execution
                        ;; The orchestration hook will natively kill the buffer once the response finishes.
                        "SUCCESS: Result submitted successfully. You have completed your task.")
