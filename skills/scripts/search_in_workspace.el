(macher-agent-make-tool macher-agent-search-in-workspace-tool
  "Search for a regular expression pattern within the strictly bounded workspace."
  :category "ro"
  :args '((:name "pattern" :type string :description "The regex pattern to search for"))
  :command-fn (lambda (payload _context _root)
                (let ((pattern (plist-get payload :pattern)))
                  (if (or (string-empty-p (string-trim pattern))
                          (string-equal pattern ".*")
                          (string-match-p "^\\s-*$" pattern))
                      (error "Regex pattern too broad. Provide a more specific search term.")
                    ;; String command means run in sandbox natively.
                    (format "rg --line-number --color=never --max-columns=150 '%s'" (replace-regexp-in-string "'" "'\\''" pattern))))))