(macher-agent-make-tool macher-agent-read-media-in-workspace-tool
  "Read a media file (e.g. image) from the workspace into the agent's visual context."
  :category "ro"
  :args '((:name "media_path" :type string :description "The path to the media file relative to the workspace root."))
  :command-fn (lambda (payload context workspace-root)
                (let* ((media_path (plist-get payload :media_path))
                       (actual-name (macher-agent--resolve-buffer-name media_path))
                       (abs-path (if workspace-root
                                     (macher-agent--resolve-safe-path actual-name workspace-root)
                                   (expand-file-name actual-name)))
                       (classification (macher-agent-context-classify-entry actual-name workspace-root))
                       (vfs-contents (when context (macher-agent--get-context-contents context)))
                       (in-vfs (assoc actual-name vfs-contents)))
                  
                  (unless (and (boundp 'gptel-track-media) gptel-track-media)
                    (error "gptel media send option is off (gptel-track-media is nil)"))
                  
                  (when (eq classification 'file)
                    (error "SECURITY ERROR: The file '%s' is classified as standard text. You must use 'read_buffer_in_workspace' instead." media_path))
                  
                  (unless (or in-vfs (file-exists-p abs-path))
                    (error "Cannot read media. The file does not exist in VFS or on disk at: %s" abs-path))
                  
                  (let* ((mime (mailcap-file-name-to-mime-type abs-path))
                         (fsm (macher-agent--get-fsm-latest))
                         (info (when fsm 
                                 (if (fboundp 'gptel-fsm-info)
                                     (funcall 'gptel-fsm-info fsm)
                                   (when (fboundp 'mock-gptel-fsm-info)
                                     (funcall 'mock-gptel-fsm-info fsm)))))
                         (session (when info (plist-get info :macher-agent-session))))
                    (unless mime
                      (error "Could not determine MIME type for media: %s" abs-path))
                    (unless session
                      (error "Could not retrieve agent session to attach media."))
                    
                    (setf (macher-agent-session-pending-media session)
                          (list (list abs-path :mime mime)))
                    
                    (cons :lisp-result (format "SUCCESS: Media '%s' has been successfully read and attached to this response. You may now analyse it immediately." actual-name))))))