;; -*- lexical-binding: t; -*-

(require 'macher-agent)

(macher-agent-define-tool macher-agent-search-buffers-in-workspace-tool
                          ("Search for a regular expression pattern across the buffers in your restricted scope."
                           "ro"
                           :args '((:name "pattern" :type string :description "The Emacs regex pattern to search for")))
                          (pattern)
                          (let* ((context (macher-agent-current-context))
                                 (workspace (when context (macher-context-workspace context)))
                                 (root-dir (when workspace (macher--workspace-root workspace)))
                                 (results nil))
                            (when context
                              (dolist (entry (macher-context-contents context))
                                (let* ((buf-name (car entry))
                                       (classification (macher-agent-context-classify-entry buf-name root-dir)))
                                  ;; Include both pure buffers and external files
                                  (when (memq classification '(buffer external))
                                    (let ((content (macher-agent--read-context-file context buf-name)))
                                      (when content
                                        (with-temp-buffer
                                          (insert content)
                                          (goto-char (point-min))
                                          (while (re-search-forward pattern nil t)
                                            (let* ((line (line-number-at-pos))
                                                   (match-content (string-trim (thing-at-point 'line t))))
                                              (push (format "%s:%d: %s" buf-name line match-content) results)))))))))
                              (if results
                                  (mapconcat #'identity (nreverse results) "\n")
                                (format "No matches found for '%s' in your scoped buffers." pattern)))))
