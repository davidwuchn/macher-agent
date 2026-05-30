(macher-agent-make-tool macher-agent-read-media-in-workspace-tool
                          ("Read a media file (e.g. image) from the workspace into the agent's visual context."
                           "ro"
                           :args '((:name "media_path" :type string :description "The path to the media file relative to the workspace root.")))
                          (media_path)
                          
                          (unless (and (boundp 'gptel-track-media) gptel-track-media)
                            (error "gptel media send option is off (gptel-track-media is nil)"))
                          
                          (let* ((context (macher-agent-current-context))
                                 (workspace (when context (macher-context-workspace context)))
                                 (workspace-root (when workspace (macher--workspace-root workspace)))
                                 (actual-name (macher-agent--resolve-buffer-name media_path))
                                 (abs-path (if workspace-root
                                               (expand-file-name actual-name workspace-root)
                                             (expand-file-name actual-name)))
                                 (vfs-contents (when context (macher-context-contents context)))
                                 (in-vfs (assoc actual-name vfs-contents)))
                            
                            (unless (or in-vfs (file-exists-p abs-path))
                              (error "Cannot read media. The file does not exist in VFS or on disk at: %s" abs-path))
                            
                            (let* ((mime (mailcap-file-name-to-mime-type abs-path))
                                   (buf (current-buffer)))
                              (unless mime
                                (error "Could not determine MIME type for media: %s" abs-path))
                              
                              (setf (alist-get buf macher-agent--pending-tool-media-alist nil nil #'equal) 
                                    (list (list abs-path :mime mime)))
                              
                              (format "SUCCESS: Media '%s' has been successfully read and attached to this response. You may now analyse it immediately." actual-name))))
