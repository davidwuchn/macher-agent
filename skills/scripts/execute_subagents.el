(macher-agent-make-tool macher-agent-execute-subagents-tool
                          ("Trigger 1-to-many sub-agents to begin processing. Does NOT provide new instructions. Supports an optional blocking flag to wait for their final output."
                           "orchestrate"
                           :async t
                           :args '((:name "buffer_names" :type array
                                          :description "List of buffer names to trigger."
                                          :items (:type string))
                                   (:name "blocking" :type boolean :optional t
                                          :description "If true, pause the parent agent and wait for all triggered agents to complete. If false (default), run asynchronously in the background.")))
                          (buffer_names &optional blocking)
                          (unless (vectorp buffer_names) (error "ERROR: 'buffer_names' parameter must be an array of strings."))
                          (let ((target-buffers nil))
                            (cl-loop for buffer_name across buffer_names do
                                     (let ((actual-name (macher-agent-workspace-resolve-path buffer_name)))
                                       (let ((buf (get-buffer actual-name)))
                                         (unless (buffer-live-p buf)
                                           (error "ERROR: Buffer '%s' does not exist." actual-name))
                                         (push buf target-buffers))))

                            (dolist (buf target-buffers)
                              (macher-agent-prepare-instructions buf "" nil))

                            (if (and blocking (not (eq blocking :json-false)))
                                (macher-agent-execute-parallel (nreverse target-buffers) callback)
                              (progn
                                (dolist (buf target-buffers)
                                  (with-current-buffer buf
                                    (macher-agent-ui-show buf)
                                    (gptel-send)))
                                (funcall callback (list :status 'success :data (format "Triggered %d sub-agents asynchronously." (length target-buffers))))))))
