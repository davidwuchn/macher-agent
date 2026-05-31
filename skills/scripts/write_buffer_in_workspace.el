(macher-agent-make-tool macher-agent-write-buffer-in-workspace-tool
                          ("Propose new content for a live Emacs buffer. This creates a virtual patch that will be presented for review rather than mutating the buffer immediately."
                           ""
                           :args '((:name "buffer_name" :type string :description "The name of the target buffer")
                                   (:name "content" :type string :description "The proposed new content for the buffer")))
                          (buffer_name content)
                          
                          (let* ((context (macher-agent-current-context))
                                 (actual-name (macher-agent-workspace-resolve-path buffer_name))
                                 (task-id (buffer-name))
                                 (deterministic-hash (secure-hash 'md5 (concat task-id ":" actual-name)))
                                 (hidden-buf-name (format " *macher-edit-%s*" deterministic-hash)))
                            
                            ;; Decouple from live buffer to avoid autosave collisions
                            (let ((target-buffer (get-buffer-create hidden-buf-name)))
                              (with-current-buffer target-buffer
                                (erase-buffer)
                                (setq-local macher-target-filepath actual-name)
                                (insert content)
                                ;; Mark as modified so it can be managed
                                (set-buffer-modified-p t)))
                            
                            (macher-agent-context-update context actual-name content)
                            (format "SUCCESS: Virtual edit recorded for buffer '%s' in unlinked scratchpad. A patch will be generated at the end of the turn." actual-name)))
