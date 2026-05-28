(require 'macher-agent)

(macher-agent-define-tool macher-agent-write-buffer-in-workspace-tool
                          ("Propose new content for a live Emacs buffer. This creates a virtual patch that will be presented for review rather than mutating the buffer immediately."
                           ""
                           :args '((:name "buffer_name" :type string :description "The name of the target buffer")
                                   (:name "content" :type string :description "The proposed new content for the buffer")))
                          (buffer_name content)
                          
                          (let* ((actual-name (macher-agent--resolve-buffer-name buffer_name)))
                            
                            ;; Unconditionally ensure the buffer exists in Emacs memory
                            (get-buffer-create actual-name)
                            
                            (macher-agent--update-context-file (macher-agent-current-context) actual-name content)
                            (format "SUCCESS: Virtual edit recorded for buffer '%s'. A patch will be generated at the end of the turn." actual-name)))
