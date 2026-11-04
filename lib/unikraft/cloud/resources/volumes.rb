# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

require_relative "../core/resource"
require_relative "../api/platform"

module Unikraft
  module Cloud
    module Resources
      # A handle on one volume (see {Core::Handle}).
      #
      # @example
      #   ukc.volumes.get(name: "data").attach(attach_to: { name: "web" }, at: "/data")
      class VolumeHandle < Core::Handle
        # Attach the volume to an instance.
        #
        # @param spec [Hash] the attachment, with the API's keys:
        #   `attach_to:` (an instance ref), `at:` (the mount point),
        #   `readonly:`; plus `headers:`/`timeout:` for the call
        # @return [VolumeHandle] carrying what the endpoint reported
        def attach(**spec) = volume_op(:attach_volumes, :attach_to, spec)

        # Detach the volume, from every instance or, with `from:` (an
        # instance ref), one.
        #
        # @return [VolumeHandle]
        def detach(**spec) = volume_op(:detach_volumes, :from, spec)

        attributes_of API::Platform::Models::Volume

        private

        # Send the operation with its instance ref as the wire carries it:
        # the identifier alone, whatever form the ref was given in.
        def volume_op(operation, key, spec)
          call = spec.slice(:headers, :timeout)
          body = wire(call).merge(spec.except(*call.keys))
          body[key] = same_metro(Core::Ref.coerce(body[key])).wire if body[key]
          mutate(operation, [body], **call)
        end

        # The wire drops the instance's metro, so one elsewhere would name
        # a different instance in this volume's metro. A URL metro matches
        # by its normalized base URL (`/v1` or not).
        def same_metro(ref)
          return ref if ref.metro.nil? || ref.metro == metro
          return ref if Core::Metro.url?(ref.metro) &&
                        Core::Metro.base_url(ref.metro) == location.base_url

          raise ArgumentError, "instance #{ref} is not in this volume's metro (#{metro})"
        end
      end

      # Every volume matching one ref, one per metro.
      class VolumeSet < Core::HandleSet
        forward :attach, :detach
      end

      # Persistent volumes. Enumerable over every volume in scope.
      #
      # @example
      #   ukc.metro(:fra).volumes.create(name: "data", size_mb: 1024)
      #   ukc.volumes.update(name: "data", size_mb: 2048)
      class Volumes < Core::Resource
        API_CLASS = API::Platform::VolumesApi
        HANDLE = VolumeHandle
        SET = VolumeSet
        SPEC = Spec.new(noun: "volume", key: :volumes, list: :get_volumes,
                        create: :create_volume, delete: :delete_volumes,
                        update: :update_volumes)

        # Shorthand for `get(ref).attach(...)`.
        #
        # @example
        #   ukc.volumes.attach(name: "data", attach_to: { name: "web" }, at: "/data")
        # @return [VolumeHandle]
        def attach(ref = nil, **kwargs)
          handle, spec = on(ref, kwargs)
          handle.attach(**spec)
        end

        # Shorthand for `get(ref).detach(...)`.
        # @return [VolumeHandle]
        def detach(ref = nil, **kwargs)
          handle, spec = on(ref, kwargs)
          handle.detach(**spec)
        end
      end
    end
  end
end
