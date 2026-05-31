(macher-agent-make-tool macher-agent-write-buffer-in-workspace-tool
                          ("Propose new content for a live Emacs buffer. This creates a virtual patch that will be presented for review rather than mutating the buffer immediately."
                           ""
                           :args '((:name "buffer_name" :type string :description "The name of the target buffer")
                                   (:name "content" :type string :description "The proposed new content for the buffer")))
                          (buffer_name content)
                          
                          (let* ((actual-name (macher-agent-workspace-resolve-path buffer_name))
                                 (task-id (buffer-name))
                                 (expected-hash (secure-hash 'md5 (concat task-id ":" actual-name)))
                                 (expected-buf-name (format " *macher-edit-%s*" expected-hash))
                                 (buf (get-buffer-create expected-buf-name)))
                            
                            (with-current-buffer buf
                              (erase-buffer)
                              (insert content)
                              (setq-local macher-target-filepath actual-name))

                            ;; Also update the context so patch generation works
                            (macher-agent--update-context-file context actual-name content)
                            
                            (format "SUCCESS: Virtual edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name)))
