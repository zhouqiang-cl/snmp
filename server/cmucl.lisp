;;;; -*- Mode: Lisp -*-
;;;; $Id: cmucl.lisp 506 2008-09-14 18:41:38Z binghe $

(in-package :snmp)

(def-scalar-variable "sysObjectID" (agent)
  (oid "clNetSnmpAgentCMUCL"))
