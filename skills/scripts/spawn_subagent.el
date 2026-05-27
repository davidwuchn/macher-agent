(macher-agent-define-tool macher-agent-spawn-subagent-tool
                          ("Spawn a new sub-agent buffer to handle delegated work." "orchestrate" 
                           :args '((:name "name" :type string)))
                          (name)
                          (let* ((ctx (macher-agent-current-context))
                                 (dir default-directory)
                                 (buf (macher-agent-add-subagent name dir nil ctx)))
                            
                            (when ctx
                              (macher-agent--add-buffer-to-scope-headless (buffer-name buf) ctx))
                            
                            (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." (buffer-name buf))))
