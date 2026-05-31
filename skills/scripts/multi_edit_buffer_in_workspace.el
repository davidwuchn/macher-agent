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
                          (let* ((actual-name (macher-agent-workspace-resolve-path buffer_name))
                                 (task-id (buffer-name))
                                 (expected-hash (secure-hash 'md5 (concat task-id ":" actual-name)))
                                 (expected-buf-name (format " *macher-edit-%s*" expected-hash))
                                 (buf (get-buffer expected-buf-name))
                                 (content (if (buffer-live-p buf)
                                              (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))
                                            (let ((contents (assoc actual-name (macher-context-contents context))))
                                              (if contents
                                                  (cdr (cdr contents))
                                                (error "Buffer '%s' not found in workspace" actual-name))))))
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
                            
                            (let ((buf (get-buffer-create expected-buf-name)))
                              (with-current-buffer buf
                                (erase-buffer)
                                (insert content)
                                (setq-local macher-target-filepath actual-name)))

                            ;; Also update the context so patch generation works
                            (macher-agent--update-context-file context actual-name content)
                            
                            (format "SUCCESS: Virtual multi-edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name)))
