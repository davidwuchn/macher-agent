(macher-agent-make-tool macher-agent-read-buffer-in-workspace-tool
                          ("Read the contents of a scoped buffer (ie a buffer in your allowed list)."
                           "ro"
                           :args '((:name "buffer_name" :type string :description "The name of the buffer to read")
                                   (:name "offset" :type number :optional t :description "Line number to start reading from (1-based)")
                                   (:name "limit" :type number :optional t :description "Number of lines to read")
                                   (:name "show_line_numbers" :type boolean :optional t :description "Include line numbers in output")))
                          (buffer_name &optional offset limit show_line_numbers)
                          (let* ((context (macher-agent-current-context))
                                 (actual-name (macher-agent-workspace-resolve-path buffer_name))
                                 (content (macher-agent-context-read context actual-name))
                                 (parsed-offset (when offset (round offset)))
                                 (parsed-limit (when limit (round limit))))
                            (macher--read-string content parsed-offset parsed-limit show_line_numbers)))
