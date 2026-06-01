(macher-agent-make-tool macher-agent-spawn-subagent-tool
  "Spawn a new sub-agent buffer to handle delegated work."
  :category "orchestrate"
  :args '((:name "name" :type string))
  :command-fn (lambda (payload)
                (let* ((name (plist-get payload :name))
                       (context (ignore-errors (macher-agent-current-context)))
                       (dir default-directory)
                       (buf (macher-agent-add-subagent name dir nil context)))
                  (when context
                    (macher-agent-scope-add-file (buffer-name buf) context))
                  (cons :lisp-result (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." (buffer-name buf))))))