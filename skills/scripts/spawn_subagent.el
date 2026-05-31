(macher-agent-make-tool macher-agent-spawn-subagent-tool
                          ("Spawn a new sub-agent buffer to handle delegated work." "orchestrate" 
                           :args '((:name "name" :type string)))
                          (name)
                          (let* ((dir default-directory)
                                 (buf (macher-agent-add-subagent name dir nil context)))
                            
                            (when context
                              (macher-agent-scope-add-file (buffer-name buf) context))
                            
                            (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." (buffer-name buf))))
