;;;; -*- Mode: Lisp -*-
;;;; $Id: message.lisp 874 2011-03-21 16:51:46Z binghe $

(in-package :snmp)

(defclass message ()
  ((session :type session
            :initarg :session
            :accessor session-of)
   (pdu     :type pdu
            :initarg :pdu
            :accessor pdu-of)
   (context :type base-string
            :initarg :context
            :accessor context-of))
  (:documentation "SNMP message base class"))

;;; SNMPv1 and SNMPv2c

(defclass v1-message (message) ()
  (:documentation "Community-based SNMP v1 Message"))

(defclass v2c-message (v1-message) ()
  (:documentation "Community-based SNMP v2c Message"))

(defmethod ber-encode ((message v1-message))
  (ber-encode (list (version-of (session-of message))
                    (community-of (session-of message))
                    (pdu-of message))))

(defgeneric decode-message (session stream))

(defmethod decode-message ((s session) (source t))
  (error "Unknown message source: ~A" source))

(defmethod decode-message ((s session) (data sequence))
  (let ((message-list (coerce (ber-decode data) 'list)))
    (decode-message s message-list)))

(defmethod decode-message ((s session) (stream stream))
  (let ((message-list (coerce (ber-decode stream) 'list)))
    (decode-message s message-list)))

(defmethod decode-message ((s v1-session) (message-list list))
  (destructuring-bind (version community pdu) message-list
    (declare (ignore version community))
    (make-instance 'v1-message :session s :pdu pdu)))

(defmethod decode-message ((s v2c-session) (message-list list))
  (destructuring-bind (version community pdu) message-list
    (declare (ignore version community))
    (make-instance 'v2c-message :session s :pdu pdu)))

;;; SNMP v3

(defclass v3-message (message)
  ;; start msgID must be big, or net-snmp cannot decode our message
  ((message-id-counter :type (unsigned-byte 32)
                       :initform 0
                       :allocation :class)
   (message-id         :type (unsigned-byte 32)
                       :initarg :id
                       :accessor message-id-of)
   ;; Report flag, for SNMP report use.
   (report-flag        :type boolean
                       :initform nil
                       :initarg :report
                       :accessor report-flag-of))
  (:documentation "User-based SNMP v3 Message"))

(defmethod generate-message-id ((message v3-message))
  (with-slots (message-id-counter) message
    (portable-threads:atomic-incf message-id-counter)
    (the (unsigned-byte 32)
      (ldb (byte 32 0) message-id-counter))))

(defmethod initialize-instance :after ((message v3-message) &rest initargs)
  (declare (ignore initargs))
  (unless (slot-boundp message 'message-id)
    (setf (message-id-of message) (generate-message-id message))))

(defun generate-global-data (id level)
  (list id
        ;; msgMaxSize
        +max-snmp-packet-size+
        ;; msgFlags: security-level + reportable flag
        (make-string 1 :initial-element (code-char (logior #b100 level)))
        ;; msgSecurityModel: USM (3)
        +snmp-sec-model-usm+))

(defvar *default-context* "")

;;; SNMPv3 Message Encode
(defmethod ber-encode ((message v3-message))
  (let* ((session (session-of message))
         (global-data (generate-global-data (message-id-of message)
                                            (if (report-flag-of message) 0
                                              (security-level-of session))))
         (message-data (list (engine-id-of session) ; contextEngineID
                             (or (context-of message)
                                 *default-context*) ; contextName
                             (pdu-of message)))     ; PDU
         (need-auth-p (and (not (report-flag-of message))
                           (auth-protocol-of session)))
         (need-priv-p (and (not (report-flag-of message))
                           (priv-protocol-of session)))
         ;; RFC 2574 (USM for SNMPv3), 7.3.1.
         ;; 1) The msgAuthenticationParameters field is set to the
         ;;    serialization, according to the rules in [RFC1906], of an OCTET
         ;;    STRING containing 12 zero octets.
         (message-authentication-parameters (if need-auth-p
                                                (make-string 12 :initial-element (code-char 0))
                                              ""))
         ;; RFC 2574 (USM for SNMPv3), 8.1.1.1. DES key and Initialization Vector
         ;; Now it's a list, not string, as we do this later.
         (message-privacy-parameters (if need-priv-p
                                   (generate-privacy-parameters message)
                                   nil)))
    ;; Privacy support (we encrypt and replace message-data here)
    (when need-priv-p
      (setf message-data (encrypt-message message message-privacy-parameters message-data)))
    ;; Authentication support
    (labels ((encode-v3-message (auth)
               (ber-encode (list (version-of session)
                                 global-data
                                 (ber-encode->string (list (engine-id-of session)
                                                           (engine-boots-of session)
                                                           (engine-time-of session)
                                                           (if (report-flag-of message)
                                                             ""
                                                             (security-name-of session))
                                                           auth
                                                           (map 'string #'code-char
                                                                message-privacy-parameters)))
                                 message-data))))
      (let ((unauth-data (encode-v3-message message-authentication-parameters)))
        (if (not need-auth-p) unauth-data
          ;; authencate the encode-data and re-encode it
          (encode-v3-message (authenticate-message
                              (coerce unauth-data 'octets)
                              (coerce (auth-local-key-of session) 'octets)
                              (auth-protocol-of session))))))))

;;; need ironclad package for hmac/md5 and hmac/sha
(defun authenticate-message (message key digest)
  (declare (type octets message key)
           (type (member :md5 :sha1) digest))
  (let ((hmac (ironclad:make-hmac key digest)))
    (ironclad:update-hmac hmac message)
    ;; TODO, use a raw-data instead, for efficiency
    (map 'string #'code-char
         (subseq (ironclad:hmac-digest hmac) 0 12))))

(defun need-report-p (session)
  "return true if a SNMPv3 session has no engine infomation set"
  (declare (type v3-session session))
  (zerop (engine-time-of session)))

(defun update-session-from-report (session security-string)
  (declare (type v3-session session)
           (type string security-string))
  (destructuring-bind (engine-id engine-boots engine-time user auth priv)
      ;; security-data: 3rd field of message list
      (coerce (ber-decode<-string security-string) 'list)
    (declare (ignore user auth priv))
    (setf (engine-id-of session) engine-id
          (engine-boots-of session) engine-boots
          (engine-time-of session) engine-time)
    (when (and (auth-protocol-of session) (slot-boundp session 'auth-key))
      (setf (auth-local-key-of session)
            (generate-kul (map 'octets #'char-code engine-id)
                          (auth-key-of session))))
    (when (and (priv-protocol-of session) (slot-boundp session 'priv-key))
      (setf (priv-local-key-of session)
            (generate-kul (map 'octets #'char-code engine-id)
                          (priv-key-of session))))
    session))

;;; SNMPv3 Message Decode
(defmethod decode-message ((s v3-session) (message-list list))
  (destructuring-bind (version global-data security-string data) message-list
    (declare (ignore version))
    (let ((message-id (elt global-data 0))
          (encrypt-flag (plusp (logand #b10
                                       (char-code (elt (elt global-data 2) 0))))))
      (when encrypt-flag
        ;;; decrypt message
        (let ((salt (map 'octets #'char-code
                         (elt (ber-decode<-string security-string) 5)))
              (des-key (subseq (priv-local-key-of s) 0 8))
              (pre-iv (subseq (priv-local-key-of s) 8 16))
              (data (map 'octets #'char-code data)))
          (let* ((iv (map 'octets #'logxor pre-iv salt))
                 (cipher (ironclad:make-cipher :des ; (priv-protocol-of s)
                                               :mode :cbc
                                               :key des-key 
                                               :initialization-vector iv)))
            (ironclad:decrypt-in-place cipher data)
            (setf data (ber-decode data)))))
      (let* ((context (elt data 1))
             (pdu     (elt data 2))
             (report-p (typep pdu 'report-pdu))
             (report-flag (and (not (need-report-p s)) report-p)))
        (when report-p
          (update-session-from-report s security-string))
        (make-instance 'v3-message
                       :session s
                       :id message-id
                       :report report-flag
                       :context context
                       :pdu pdu)))))

;;; RFC 2574 (USM for SNMPv3), 8.1.1.1. DES key and Initialization Vector
(defun generate-privacy-parameters (message)
  (declare (type v3-message message))
  "generate a 8-bytes privacy-parameters string for use by message encrypt"
  (let ((left  (engine-boots-of (session-of message))) ; octets 0~3
        (right (message-id-of message)))                   ; octets 4~7 (we just reuse msgID)
    (let ((salt (logior (ash left 32) right))
          (result nil))
      (dotimes (i 8 result)
        (push (logand salt #xff) result)
        (setf salt (ash salt -8))))))

;;; Encrypt msgData
(defun encrypt-message (message message-privacy-parameters message-data)
  (declare (type v3-message message)
           (type list message-privacy-parameters message-data))
  (let ((salt (coerce message-privacy-parameters 'octets))
        (pre-iv (subseq (priv-local-key-of (session-of message)) 8 16))
        (des-key (subseq (priv-local-key-of (session-of message)) 0 8))
        (data (coerce (ber-encode message-data) 'octets)))
    (let ((iv (map 'octets #'logxor pre-iv salt))
          (result-length (* (1+ (floor (length data) 8)) 8))) ;; extend length to (mod 8)
      (let ((cipher (ironclad:make-cipher :des ; (priv-protocol-of (session-of message))
                                          :key des-key
                                          :mode :cbc
                                          :initialization-vector iv))
            (result-data (make-sequence 'octets result-length :initial-element 0)))
        (replace result-data data)
        (ironclad:encrypt-in-place cipher result-data)
        (map 'string #'code-char result-data)))))

(defvar *session->message* (make-hash-table :test 'eq :size 3))

(eval-when (:load-toplevel :execute)
  (setf (gethash 'v1-session *session->message*) 'v1-message
        (gethash 'v2c-session *session->message*) 'v2c-message
        (gethash 'v3-session *session->message*) 'v3-message))
