;;; pm-kernel.el --- Kernel Project Management

;; Copyright (C) 2019 Julien Masson

;; Author: Julien Masson <massonju.eseo@gmail.com>
;; URL: https://github.com/JulienMasson/jm-config/

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:

(require 'project-manager)
(require 'multi-term)
(require 'rg)

(defcustom pm-kernel-local-debug-toolchain nil
  "Local toolchain used when debugging remote project root path")

(defcustom pm-kernel-local-sshfs-dir (format "/home/%s/.cache/project-manager/"
					     (getenv "USER"))
  "Local directory used to sshfs remote project root path when debugging")

;; External
(defvar kernel-arch nil)
(defvar kernel-cross-compile nil)
(defvar kernel-defconfig nil)
(defvar kernel-toolchain-path nil)
(defvar kernel-out-files nil)

;; Internal
(defvar pm-kernel-subprojects-history '())
(defvar pm-kernel-targets
  '(("kernel"		.	pm-kernel-build-kernel)
    ("modules"		.	pm-kernel-build-modules)
    ("headers"		.	pm-kernel-build-headers)
    ("all"		.	pm-kernel-build-all)
    ("clean"		.	"make clean")
    ("olddefconfig"	.	"make olddefconfig")
    ("defconfig"	.	pm-kernel-build-defconfig)
    ("menuconfig"	.	pm-kernel-make-menuconfig)))

(defvar pm-kernel-search-tools
  '(("rg"	.	pm-kernel-rg)
    ("grep"	.	pm-kernel-grep)))

(defvar pm-kernel-debug-default-port "/dev/ttyUSB0")
(defvar pm-kernel-debug-default-speed 115200)

(defun pm-kernel-path-env ()
  (format "PATH=%sbin:$PATH" (untramp-path kernel-toolchain-path)))

(defun pm-kernel-compile-env ()
  (format "ARCH=%s CROSS_COMPILE=%s" kernel-arch kernel-cross-compile))

(defun pm-kernel-term-send-command (cmd)
  (term-send-raw-string cmd)
  (term-send-return))

(defun pm-kernel-term-setup-remote (buffer)
  (let* ((dissect (tramp-dissect-file-name current-root-path))
	 (user (tramp-file-name-user dissect))
	 (host (tramp-file-name-host dissect))
	 (ssh-cmd (concat "ssh " (if user (format "%s@" user)) host))
	 (path-cmd (concat "cd " (untramp-path current-root-path))))
    (pm-kernel-term-send-command ssh-cmd)
    (pm-kernel-term-send-command path-cmd)))

(defun pm-kernel-make-menuconfig ()
  (interactive)
  (let* ((default-directory current-root-path)
	 (path-env (pm-kernel-path-env))
	 (compile-env (pm-kernel-compile-env))
	 (buffer-name (format "menuconfig-%s" (project-name current-project)))
	 (term-buffer (make-term buffer-name "/bin/bash")))
    (set-buffer term-buffer)
    (multi-term-internal)
    (when (tramp-tramp-file-p current-root-path)
      (pm-kernel-term-setup-remote term-buffer))
    (pm-kernel-term-send-command (format "export %s %s" path-env compile-env))
    (pm-kernel-term-send-command "make menuconfig")
    (setq-local global-hl-line-mode nil)
    (switch-to-buffer term-buffer)))

(defun pm-kernel-build-target (target)
  (let ((default-directory current-root-path)
	(path-env (pm-kernel-path-env))
	(compile-env (pm-kernel-compile-env)))
    (compile (format "export %s %s && %s" path-env compile-env target))))

(defun pm-kernel-cmd ()
  (let* ((local-path (untramp-path kernel-out-files))
	 (clean (format "rm -f %sImage %sconfig-* %sSystem.map-* %svmlinuz-*"
			local-path local-path local-path local-path))
	 (build-cmd "make -j$(nproc)")
	 (install-cmd (concat "make install INSTALL_PATH=" local-path))
	 (image-copy (format "cp arch/%s/boot/Image %s" kernel-arch local-path)))
    (format "%s && %s && %s && %s" build-cmd clean install-cmd image-copy)))

(defun pm-kernel-build-kernel ()
  (pm-kernel-build-target (pm-kernel-cmd)))

(defun pm-kernel-modules-cmd ()
  (let* ((local-path (untramp-path kernel-out-files))
	 (clean (format "rm -rf %slib" local-path)))
    (format "%s && make modules_install INSTALL_MOD_PATH=%s" clean local-path)))

(defun pm-kernel-build-modules ()
  (pm-kernel-build-target (pm-kernel-modules-cmd)))

(defun pm-kernel-headers-cmd ()
  (let* ((local-path (untramp-path kernel-out-files))
	 (clean (format "rm -rf %sinclude" local-path)))
    (format "%s && make headers_install INSTALL_HDR_PATH=%s" clean local-path)))

(defun pm-kernel-build-headers ()
  (pm-kernel-build-target (pm-kernel-headers-cmd)))

(defun pm-kernel-build-all ()
  (let* ((kernel-cmd (pm-kernel-cmd))
	 (modules-cmd (pm-kernel-modules-cmd))
	 (headers-cmd (pm-kernel-headers-cmd)))
    (pm-kernel-build-target (format "%s && %s && %s && %s"
				    kernel-cmd modules-cmd headers-cmd))))

(defun pm-kernel-build-defconfig ()
  (pm-kernel-build-target (concat "make " kernel-defconfig)))

(defun pm-kernel-compile (target)
  (interactive (list (completing-read "Build target: "
				      (mapcar 'car pm-kernel-targets))))
  (let ((t-or-f (assoc-default target pm-kernel-targets)))
    (if (functionp t-or-f)
	(funcall t-or-f)
      (pm-kernel-build-target t-or-f))))

(defun pm-kernel-build-subprojects ()
  (append `(("root"	.	,current-root-path)
	    ("out"	.	,kernel-out-files)
	    ("docs"	.	,(concat current-root-path "Documentation")))
	  (mapcar (lambda (p)
		    `(,(car p) . ,(concat current-root-path (cdr p))))
		  (project-subprojects current-project))))

(defun pm-kernel-ido-find-file ()
  (interactive)
  (let* ((subprojects (pm-kernel-build-subprojects))
	 (subprojects (cl-remove-if-not 'file-directory-p subprojects
					:key #'cdr))
	 (subproject (ido-completing-read (format "Subproject (project %s): "
						  (project-name current-project))
					  subprojects
					  nil t nil 'pm-kernel-subprojects-history))
	 (default-directory (assoc-default subproject subprojects)))
    (ido-find-file)))

(defun pm-kernel-grep (search)
  (interactive "sGrep search: ")
  (let ((default-directory current-root-path))
    (grep (concat grep-command " --include=\"*.[c|h]\" " search))))

(defun pm-kernel-rg (search)
  (interactive "sRipgrep search: ")
  (let ((default-directory current-root-path))
    (rg-run search "all" current-root-path)))

(defun pm-kernel-search (tools)
  (interactive (list (completing-read "Search tools: "
				      (mapcar 'car pm-kernel-search-tools))))
  (call-interactively (assoc-default tools pm-kernel-search-tools)))

(defun pm-kernel-check-sshfs (src dest)
  (seq-find (lambda (line)
	      (string-match-p (format "^%s on %s type.*" src dest) line))
	    (process-lines "mount")))

(defun pm-kernel-vmlinux-path ()
  (if (tramp-tramp-file-p current-root-path)
      (let ((src (replace-regexp-in-string "^/ssh:\\(.*\\)/$" "\\1"
					   current-root-path))
	    (dest (concat pm-kernel-local-sshfs-dir
			  (project-name current-project))))
	(unless (pm-kernel-check-sshfs src dest)
	  (unless (file-directory-p dest)
	    (mkdir dest))
	  (shell-command (format "sshfs %s %s" src dest)))
	(concat dest "/vmlinux"))
    (concat current-root-path "vmlinux")))

(defun pm-kernel-debug-toolchain-path ()
  (format "%sbin/%sgdb" (if (tramp-tramp-file-p current-root-path)
			    pm-kernel-local-debug-toolchain
			  kernel-toolchain-path)
	  kernel-cross-compile))

(defun pm-kernel-debug (trigger)
  (interactive (list (yes-or-no-p "Trigger KGDB ? ")))
  (let ((default-directory current-root-path)
	(gdb-default-cmd (pm-kernel-debug-toolchain-path))
	(vmlinux (pm-kernel-vmlinux-path))
	(port pm-kernel-debug-default-port)
	(speed pm-kernel-debug-default-speed)
	(kgdb-default-root-cmd "sudo su"))
    (kgdb vmlinux port speed trigger)))

(pm-register-backend
 (make-pm-backend :name "kernel"
		  :find-file 'pm-kernel-ido-find-file
		  :search 'pm-kernel-search
		  :compile 'pm-kernel-compile
		  :debug 'pm-kernel-debug))

(provide 'pm-kernel)
