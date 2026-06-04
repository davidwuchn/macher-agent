(macher-agent-make-tool macher-agent-read-media-in-workspace-tool
                        "Read a media file (e.g. image) from the workspace into the agent's visual context."
                        :category "ro"
                        :args '((:name "media_path" :type string :description "The path to the media file relative to the workspace root."))
                        :command-fn (lambda (payload)
                                      (let* ((media_path (plist-get payload :media_path))
                                             (context (ignore-errors (macher-agent-current-context)))
                                             (workspace (when context (macher-agent--get-context-workspace context)))
                                             (workspace-root (when workspace (macher-agent--get-workspace-root workspace)))
                                             (actual-name (if (fboundp 'macher-agent--resolve-buffer-name)
                                                              (macher-agent--resolve-buffer-name media_path)
                                                            media_path))
                                             (abs-path (if workspace-root
                                                           (expand-file-name actual-name workspace-root)
                                                         (expand-file-name actual-name)))
                                             (vfs-contents (when context (macher-agent--get-context-contents context)))
                                             (in-vfs (assoc actual-name vfs-contents)))
                                        
                                        (unless (and (boundp 'gptel-track-media) gptel-track-media)
                                          (error "gptel media send option is off (gptel-track-media is nil)"))
                                        
                                        (unless (or in-vfs (file-exists-p abs-path))
                                          (error "Cannot read media. The file does not exist in VFS or on disk at: %s" abs-path))
                                        
                                        (let* ((mime (mailcap-file-name-to-mime-type abs-path))
                                               (info (when (bound-and-true-p macher--fsm-latest)
                                                       (if (fboundp 'gptel-fsm-info)
                                                           (funcall 'gptel-fsm-info macher--fsm-latest)
                                                         (when (fboundp 'mock-gptel-fsm-info)
                                                           (funcall 'mock-gptel-fsm-info macher--fsm-latest)))))
                                               (session (when info (plist-get info :macher-agent-session))))
                                          (unless mime
                                            (error "Could not determine MIME type for media: %s" abs-path))
                                          
                                          ;; FIX: Auto-generate session if bypassed by sub-agent orchestrator
                                          (unless session
                                            (setq session (make-macher-agent-session :id (buffer-name) :workspace workspace))
                                            (when info
                                              (setf (gptel-fsm-info macher--fsm-latest) (plist-put info :macher-agent-session session))))
                                          
                                          (setf (macher-agent-session-pending-media session)
                                                (list (list abs-path :mime mime)))
                                          
                                          ;; FIX: Must return the struct
                                          (make-macher-agent-tool-response 
                                           :type 'lisp-result 
                                           :payload (format "SUCCESS: Media '%s' has been successfully read and attached to this response. You may now analyse it immediately." actual-name))))))
