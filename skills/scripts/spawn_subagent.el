(macher-agent-make-tool macher-agent-spawn-subagent-tool
                        "Spawn a new sub-agent buffer to handle delegated work."
                        :category "orchestrate"
                        :args '((:name "name" :type string)
                                (:name "preset" :type string :description "The SKILL.md preset to apply" :optional t))
                        :command-fn (lambda (payload)
                                      (let* ((name (plist-get payload :name))
                                             (preset (plist-get payload :preset))
                                             (context (ignore-errors (macher-agent-resolve-context)))
                                             (dir default-directory)
                                             (buf (macher-agent-add-subagent name dir nil context preset)))
                                        (make-macher-agent-lisp-result-response 
                                         :payload (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." (buffer-name buf))))))
