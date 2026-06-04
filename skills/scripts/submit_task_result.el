(macher-agent-make-tool macher-agent-submit-task-result-tool
                        "Submit the final result of your assigned task back to the orchestrator."
                        :category "worker"
                        :args '((:name "final_answer" :type string :description "The final answer, data, or summary of completed work."))
                        :command-fn (lambda (payload)
                                      (let* ((final_answer (plist-get payload :final_answer))
                                             (worker-id (buffer-name (current-buffer))))
                                        
                                        ;; Synchronously hand the result back to the parent
                                        (when (boundp 'macher-agent--parent-callback)
                                          (funcall macher-agent--parent-callback 
                                                   (list :status 'success :data final_answer :buffer_name worker-id)))
                                        
                                        ;; Flag the buffer so the global idle timer knows it's safe to reap
                                        (setq-local macher-agent-task-finished t)
                                        
                                        (make-macher-agent-tool-response 
                                         :type 'lisp-result 
                                         :payload "SUCCESS: Result submitted."))))
