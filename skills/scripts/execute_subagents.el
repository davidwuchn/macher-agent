(macher-agent-make-tool macher-agent-execute-subagents-tool
                        "Execute multiple sub-agents asynchronously or synchronously."
                        :category "orchestrate"
                        :args '((:name "buffer_names" :type array :items (:type string))
                                (:name "blocking" :type boolean :optional t))
                        :command-fn (lambda (payload context root)
                                      (let ((buffer_names (plist-get payload :buffer_names))
                                            (blocking (plist-get payload :blocking)))
                                        (let ((tasks (cl-loop for buf in (append buffer_names nil)
                                                              collect (list :buffer_name buf :instructions "" :preset nil))))
                                          (if (and blocking (not (eq blocking :json-false)))
                                              (cons :delegate (vconcat tasks))
                                            (progn
                                              (cl-loop for buf in (append buffer_names nil) do
                                                       (let* ((actual-name (macher-agent--resolve-buffer-name buf))
                                                              (target-buffer (get-buffer actual-name)))
                                                         (when (buffer-live-p target-buffer)
                                                           (with-current-buffer target-buffer
                                                             (gptel-send)))))
                                              (cons :lisp-result (format "Triggered %d sub-agents asynchronously." (length buffer_names))))))))
                        :success-fn (lambda (results)
                                      (if (stringp results)
                                          results
                                        (let ((output (list "Execution complete. Outputs:\n")))
                                          (cl-loop for res across (if (vectorp results) results (vconcat results))
                                                   do (push (format "=== %s ===\n%s\n" 
                                                                    (plist-get res :buffer_name)
                                                                    (if (eq (plist-get res :status) 'success)
                                                                        (plist-get res :data)
                                                                      (plist-get res :error)))
                                                            output))
                                          (string-join (nreverse output) "\n")))))
