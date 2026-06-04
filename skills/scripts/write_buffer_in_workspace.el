(macher-agent-make-tool macher-agent-write-buffer-in-workspace-tool
  "Propose new content for a live Emacs buffer. This creates a virtual patch that will be presented for review rather than mutating the buffer immediately."
  :category "workspace"
  :args '((:name "buffer_name" :type string :description "The name of the target buffer")
          (:name "content" :type string :description "The proposed new content for the buffer"))
  :command-fn (lambda (payload context _root)
                (let* ((buffer_name (plist-get payload :buffer_name))
                       (content (plist-get payload :content))
                       (actual-name (macher-agent--resolve-buffer-name buffer_name)))
                  
                  (unless (stringp buffer_name)
                    (error "Wrong type argument: stringp, %s" buffer_name))
                  (unless (stringp content)
                    (error "Wrong type argument: stringp, %s" content))

                  (when context
                    (macher-agent--update-context-file context actual-name content))
                  
                  (make-macher-agent-tool-response :type 'lisp-result :payload (format "SUCCESS: Virtual edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name)))))