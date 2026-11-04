# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../core/resource"
require_relative "../api/platform"

module Unikraft
  module Cloud
    module Resources
      # A handle on one certificate (see {Core::Handle}). A certificate is
      # replaced rather than patched, so `update` takes the new `chain:` and
      # `pkey:`, and there is no `edit`.
      class CertificateHandle < Core::Handle
        undef_method :edit

        # Replace the certificate chain and private key.
        #
        # @example
        #   ukc.certificates.get(name: "star").update(chain: pem, pkey: key)
        # @param spec [Hash] `chain:`, `pkey:`; plus `headers:`/`timeout:`
        # @return [CertificateHandle]
        def update(**spec)
          call = spec.slice(:headers, :timeout)
          mutate(@resource.spec.update, [wire(call).merge(spec.except(*call.keys))], **call)
        end

        attributes_of API::Platform::Models::Certificate
      end

      # Every certificate matching one ref, one per metro.
      class CertificateSet < Core::HandleSet
        undef_method :edit
      end

      # TLS certificates.
      class Certificates < Core::Resource
        API_CLASS = API::Platform::CertificatesApi
        HANDLE = CertificateHandle
        SET = CertificateSet
        SPEC = Spec.new(noun: "certificate", key: :certificates, list: :get_certificates,
                        create: :create_certificate, delete: :delete_certificates,
                        update: :update_certificates)

        undef_method :edit

        # Shorthand for `get(ref).update(chain:, pkey:)`.
        # @return [CertificateHandle]
        def update(ref = nil, **kwargs)
          handle, spec = on(ref, kwargs)
          handle.update(**spec)
        end
      end
    end
  end
end
