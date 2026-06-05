(macher-agent-make-tool macher-agent-search-in-workspace-tool
                        "Search for a regular expression pattern within the strictly bounded workspace."
                        :category "ro"
                        :args '((:name "pattern" :type string :description "The regex pattern to search for"))
                        :command-fn (lambda (payload context _root)
                                      (let ((pattern (plist-get payload :pattern)))
                                        (if (or (string-empty-p (string-trim pattern))
                                                (string-equal pattern ".*")
                                                (string-match-p "^\\s-*$" pattern))
                                            (error "Regex pattern too broad. Provide a more specific search term.")
                                          (let ((output ""))
                                            ;; 1. Boot up the VFS sandbox (rsync + live buffer overlay)
                                            (macher-agent-with-strict-vfs-pipeline context
                                                                                   ;; 2. Run ripgrep inside the sandbox where default-directory is bound
                                                                                   (let ((cmd (format "rg --line-number --color=never --max-columns=150 '%s' . || echo 'No matches found.'" 
                                                                                                      (replace-regexp-in-string "'" "'\\''" pattern))))
                                                                                     (setq output (shell-command-to-string cmd))))
                                            ;; 3. Return the evaluated text to the agent, not a background process
                                            (make-macher-agent-tool-response :type 'text :payload output))))))
