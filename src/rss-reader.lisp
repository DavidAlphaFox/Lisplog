; -*- mode: lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Simple RSS reader
;;;

(in-package :lisplog)

(defclass rss ()
  ((title :accessor title :initarg :title :initform nil)
   (feed-link :accessor feed-link :initarg :feed-link :initform nil)
   (link :accessor link :initarg :link :initform nil)
   (updated-time :accessor updated-time :initarg :updated-time :initform nil)
   (subtitle :accessor subtitle :initarg :subtitle :initform nil)
   (editor :accessor editor :initarg :editor :initform nil)
   (entries :accessor entries :initarg :entries :initform nil)
   (raw-parse :accessor raw-parse :initarg :raw-parse :initform nil)))

(defmethod print-object ((rss rss) stream)
  (print-unreadable-object (rss stream :type t)
    (format stream "~s ~s" (title rss) (feed-link rss))))

(defclass rss-entry ()
  ((rss :accessor rss :initarg :rss :initform nil)
   (title :accessor title :initarg :title :initform nil)
   (link :accessor link :initarg :link :initform nil)
   (id :accessor id :initarg :id :initform nil)
   (published-time :accessor published-time :initarg :published-time :initform nil)
   (pulished-time-string :accessor published-time-string
                         :initarg :published-time-string
                         :initform nil)
   (updated-time :accessor updated-time :initarg :updated-time :initform nil)
   (summary :accessor summary :initarg :summary :initform nil)
   (author :accessor author :initarg :author :initform nil)
   (author-uri :accessor author-uri :initarg :author-uri :initform nil)
   (content  :accessor content  :initarg :content  :initform nil)))

(defmethod print-object ((entry rss-entry) stream)
  (print-unreadable-object (entry stream :type t)
    (format stream "~s" (title entry))))

(defun remove-namespaces-from-xml (xml)
  (when (and (listp xml)
             (consp (car xml))
             (stringp (caar xml))
             (stringp (cdar xml)))
    (setf (car xml) (caar xml)))
  (when (and (listp xml) (listp (cddr xml)))
    (mapc #'remove-namespaces-from-xml (cddr xml)))
  xml)

(defun cadr-assoc (key list &key (test #'equal))
  (cadr (assoc key list :test test)))

;; This currently groks two formats:
;; Atom: (parse-rss "http://www.antipope.org/charlie/blog-static/atom.xml")
;; Simple RSS: (parse-rss "http://billstclair.com/journal/rss.xml")
(defun parse-rss (url)
  (let* ((xml
          (let ((s (drakma:http-request
                    url
                    :want-stream t
                    :connection-timeout 5)))
            (unwind-protect
                 (remove-namespaces-from-xml
                  (or (xmls:parse s) (error "Empty RSS at ~s" url)))
              (close s))))
         (rss (make-instance 'rss
                             :feed-link url
                             :raw-parse xml)))
    ;; We ignore the outermost tag for now.
    ;; Its name and attributes might eventually be useful for something
    (and (listp xml)
         (listp (cdr xml))
         (parse-rss-xml (cddr xml) rss))))

(defun parse-rss-xml (xml rss)
  (loop for element in xml
     for (tag attributes . body) = (and (listp element)
                                        (listp (cdr element))
                                        element)
     for value = (car body)
     do (cond ((null tag))
              ((equal tag "channel")  ;RSS, not ATOM
               (return-from parse-rss-xml (parse-rss-xml body rss)))
              ((equal tag "title")
               (when (stringp value)
                 (setf (title rss) value)))
              ((equal tag "link")
               (cond (attributes
                      (let ((href (cadr-assoc "href" attributes))
                            (type (cadr-assoc "type" attributes))
                            (rel (cadr-assoc "rel" attributes)))
                        (declare (ignore rel))
                        (when (equal type "text/html")
                          (setf (link rss) href))))
                     ((stringp value) (setf (link rss) value))))
              ((equal tag "updated")
               (when (stringp value)
                 (setf (updated-time rss) (parse-iso8601-time value))))
              ((or (equal tag "subtitle") (equal tag "description"))
               (when (stringp value)
                 (setf (subtitle rss) value)))
              ((equal tag "managingEditor")
               (when (stringp value)
                 (setf (editor rss) value)))
              ((or (equal tag "entry") (equal tag "item"))
               (push (parse-rss-entry rss body) (entries rss)))))
  (setf (entries rss) (nreverse (entries rss)))
  rss)

(defun parse-rss-entry (rss entry)
  (let ((res (make-instance 'rss-entry :rss rss)))
    (loop for element in entry
       for (tag attributes . body) = (and (listp element)
                                          (listp (cdr element))
                                          element)
       for value = (car body)
       do (cond ((null tag) nil)
                ((equal tag "title")
                 (when (stringp value)
                   (setf (title res) value)))
                ((equal tag "link")
                 (cond (attributes
                        (let ((href (cadr-assoc "href" attributes)))
                          (when (stringp href)
                            (setf (link res) href))))
                       ((stringp value) (setf (link res) value))))
                ((equal tag "id")
                 (when (stringp value)
                   (setf (id res) value)))
                ((equal tag "published")
                 (when (stringp value)
                   (setf (published-time-string res) value
                         (published-time res) (parse-iso8601-time value))))
                ((equal tag "updated")
                 (when (stringp value)
                   (setf (updated-time res) (parse-iso8601-time value))))
                ((equal tag "pubDate")
                 (when (stringp value)
                   (setf (published-time-string res) value
                         (published-time res) (parse-rfc-1123-date value))))
                ((equal tag "summary")
                 (when (stringp value)
                   (setf (summary res) value)))
                ((equal tag "creator")
                 (when (stringp value)
                   (setf (author res) value)))
                ((equal tag "author")
                 (loop for elt in body
                    for (tag attributes value) = (and (listp elt)
                                                      (listp (cdr elt))
                                                      elt)
                    do
                      (cond ((null tag) attributes)
                            ((equal tag "name")
                             (when (stringp value)
                               (setf (author res) value)))
                            ((equal tag "uri")
                             (when (stringp value)
                               (setf (author-uri res) value))))))
                ((or (equal tag "content")     ;ATOM
                     (equal tag "description") ;RSS
                     (equal tag "encoded"))    ;Wired
                 (when (and (stringp value)
                            (not (content res)))
                   (setf (content res) value)))))
    res))

;;;
;;; Database
;;;
;;; rss/
;;;   settings    ;; (:update-period <seconds>
;;;               ;;  :last-update <time>)
;;;               ;;  :current-page <integer>
;;;               ;;  :max-pages <integer>)
;;;   feedurls    ;; (<url> <url> ...)
;;;   feeds/
;;;     <hash>    ;; ((<url> :last-pubdate <time>) ...)
;;;   index       ;; plist to generate index.html (latest page)
;;;

(defun rss-settings (&optional (db *data-db*))
  (sexp-get db $RSS $SETTINGS :subdirs-p nil))

(defun (setf rss-settings) (settings &optional (db *data-db*))
  (setf (sexp-get db $RSS $SETTINGS :subdirs-p nil) settings))

(defun rss-setting (key &optional (db *data-db*))
  (getf (rss-settings db) key))

(defun (setf rss-setting) (value key &optional (db *data-db*))
  (setf (getf (rss-settings db) key) value))

(defun rss-feedurls (&optional (db *data-db*))
  (sexp-get db $RSS $FEEDURLS :subdirs-p nil))
  
(defun (setf rss-feedurls) (urls &optional (db *data-db*))
  (setf (sexp-get db $RSS $FEEDURLS :subdirs-p nil) urls))

(defparameter $RSS/FEEDS (fsdb:append-db-keys $RSS $FEEDS))

(defun feed-hash-settings (hash &optional (db *data-db*))
  (sexp-get db $RSS/FEEDS hash :subdirs-p nil))

(defun (setf feed-hash-settings) (settings hash &optional (db *data-db*))
  (setf (sexp-get db $RSS/FEEDS hash :subdirs-p nil) settings))

(defun feed-settings (url &optional (db *data-db*))
  (cdr (assoc url (feed-hash-settings (cl-crypto:sha1 url) db)
              :test #'equal)))

(defun (setf feed-settings) (settings url &optional (db *data-db*))
  (let* ((hash (cl-crypto:sha1 url))
         (hash-settings (feed-hash-settings hash db))
         (cell (assoc url hash-settings :test #'equal)))
    (cond (cell (setf (cdr cell) settings))
          (t (push (cons url settings) hash-settings)))
    (setf (feed-hash-settings hash db) hash-settings)
    settings))

(defun feed-setting (url key &optional (db *data-db*))
  (getf (feed-settings url db) key))
  
(defun (setf feed-setting) (value url key &optional (db *data-db*))
  (setf (getf (feed-settings url db) key) value))
  
(defun rss-index (&optional (db *data-db*))
  (sexp-get db $RSS $INDEX :subdirs-p nil))

(defun (setf rss-index) (plist &optional (db *data-db*))
  (setf (sexp-get db $RSS $INDEX :subdirs-p nil) plist))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Copyright 2013 Bill St. Clair
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions
;;; and limitations under the License.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
