(macher-agent-make-tool macher-agent-search-in-workspace-tool
  ("Search for a regular expression pattern within the strictly bounded workspace."
   "ro"
   :args '((:name "pattern" :type string :description "The regex pattern to search for"))
   :async t
   :sandbox t)
  (pattern)
  (if (or (string-empty-p (string-trim pattern))
          (string-equal pattern ".*")
          (string-match-p "^\\s-*$" pattern))
      (error "Regex pattern too broad. Provide a more specific search term.")
    (let* ((default-directory sandbox-dir)
           (out-buf (generate-new-buffer " *macher-rg-out*")))
      (set-process-sentinel
       (start-file-process "rg-search" out-buf "rg" "--line-number" "--color=never" "--max-columns=150" pattern)
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let* ((exit-code (process-exit-status proc))
                  (output (with-current-buffer out-buf (buffer-string))))
             (kill-buffer out-buf)
             (let ((final-str (if (string-empty-p (string-trim output))
                                  (format "No matches found for '%s'." pattern)
                                (concat output "\n\n[Note: Output is truncated to matches.]"))))
               (funcall callback (list :status 'success :data final-str))))))))))
