(macher-agent-make-tool macher-agent-read-buffer-in-workspace-tool
                          ("Read the contents of a scoped buffer (ie a buffer in your allowed list)."
                           "ro"
                           :args '((:name "buffer_name" :type string :description "The name of the buffer to read")
                                   (:name "offset" :type number :optional t :description "Line number to start reading from (1-based)")
                                   (:name "limit" :type number :optional t :description "Number of lines to read")
                                   (:name "show_line_numbers" :type boolean :optional t :description "Include line numbers in output")))
                          (buffer_name &optional offset limit show_line_numbers)
                          (let* ((actual-name (macher-agent-workspace-resolve-path buffer_name))
                                 (parsed-offset (when offset (round offset)))
                                 (parsed-limit (when limit (round limit))))
                            (macher-agent--ensure-access context actual-name)
                            (let* ((contents (assoc actual-name (macher-context-contents context)))
                                   (content (if contents (cdr (cdr contents))
                                              (with-current-buffer (get-buffer actual-name)
                                                (buffer-substring-no-properties (point-min) (point-max))))))
                              (macher--read-string content parsed-offset parsed-limit show_line_numbers))))
