(macher-agent-make-tool macher-agent-multi-edit-buffer-in-workspace-tool
                          ("Apply 1-to-many replacements to one scoped buffer in your workspace sequentially. All edits use exact text matching (whitespace, newlines, indentation). Use actual content - NO line numbers.\n\nEdits apply in array order. If ANY edit fails, ALL changes are rolled back."
                           ""
                           :args '((:name "buffer_name" :type string :description "The name of the target buffer")
                                   (:name "edits" :type array :description "Array of edit operations to apply in sequence"
                                          :items (:type object
                                                        :properties (:old_text (:type string :description "Exact text to find and replace.")
                                                                               :new_text (:type string :description "Text to replace the old_text with")
                                                                               :replace_all (:type boolean :description "If true, replace all occurrences."))
                                                        :required ["old_text" "new_text"]))))
                          (buffer_name edits)
                          (let* ((context (macher-agent-current-context))
                                 (actual-name (macher-agent-workspace-resolve-path buffer_name))
                                 (content (macher-agent-context-read context actual-name))
                                 (task-id (buffer-name))
                                 (deterministic-hash (secure-hash 'md5 (concat task-id ":" actual-name)))
                                 (hidden-buf-name (format " *macher-edit-%s*" deterministic-hash)))
                            (unless (vectorp edits)
                              (error "The 'edits' parameter must be an array of objects"))
                            (cl-loop for edit across edits do
                                     (let* ((old-text (plist-get edit :old_text))
                                            (new-text (plist-get edit :new_text))
                                            (replace-all (plist-get edit :replace_all))
                                            (replace-all-bool (and replace-all (not (eq replace-all :json-false)))))
                                       (unless (and old-text new-text)
                                         (error "Each edit must contain old_text and new_text properties"))
                                       (setq content (macher--edit-string content old-text new-text replace-all-bool))))
                            
                            ;; Decoupled ephemeral scratchpad to avoid live auto-save mutations
                            (let ((target-buffer (get-buffer-create hidden-buf-name)))
                              (with-current-buffer target-buffer
                                (erase-buffer)
                                (setq-local macher-target-filepath actual-name)
                                (insert content)
                                (set-buffer-modified-p t)))
                                
                            (macher-agent-context-update context actual-name content)
                            (format "SUCCESS: Virtual multi-edit recorded for buffer '%s' in unlinked scratchpad. A patch will be generated at the end of the turn." actual-name)))
