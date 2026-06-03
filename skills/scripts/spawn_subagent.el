(macher-agent-make-tool macher-agent-spawn-subagent-tool
                        "Spawn a background sub-agent for delegation."
                        :category "orchestrate"
                        :args '((:name "name" :type "string" :description "Name of the agent"))
                        :command-fn (lambda (payload context root)
                                      (let* ((name (plist-get payload :name))
                                             (buf (macher-agent-add-subagent name default-directory nil context nil)))
                                        (when context (macher-agent-scope-add-file (buffer-name buf) context))
                                        (cons :lisp-result (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." (buffer-name buf)))))
                        :success-fn nil)
