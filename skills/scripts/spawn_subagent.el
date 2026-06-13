(macher-agent-make-tool macher-agent-spawn-subagent-tool
    "Spawn a new sub-agent buffer to handle delegated work."
  :category "orchestrate"
  :args '((:name "name" :type string)
          (:name "presets" :type array :items (:type string) :description "Array of SKILL.md presets to apply" :optional t))
  :command-fn (lambda (payload)
                (let* ((name (plist-get payload :name))
                       (raw-presets (plist-get payload :presets))
                       (preset-list (cond ((vectorp raw-presets) (append raw-presets nil))
                                          ((stringp raw-presets) (list raw-presets))
                                          ((listp raw-presets) raw-presets)
                                          (t nil)))
                       (context (ignore-errors (macher-agent-resolve-context)))
                       (dir default-directory)
                       (buf (macher-agent-add-subagent name dir nil context preset-list)))
                  (make-macher-agent-lisp-result-response 
                   :payload (format "SUCCESS: Sub-agent created. The EXACT buffer name to use is '%s'." (buffer-name buf))))))
