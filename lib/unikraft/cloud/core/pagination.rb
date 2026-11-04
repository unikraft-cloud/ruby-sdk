# frozen_string_literal: true

# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Unikraft GmbH.

module Unikraft
  module Cloud
    module Core
      # Following a list endpoint's pages. The platform API pages with a
      # `count` page size and a `from` cursor (exclusive); a page shorter than
      # `count` is the last.
      module Pagination
        DEFAULT_PAGE_SIZE = 100

        module_function

        # Yield every item of every page, fetching a page only when the
        # previous one is used up.
        #
        # @param fetch [#call] `(count, from)` -> the page, an Array
        # @param page_size [Integer, nil] defaults to {DEFAULT_PAGE_SIZE}
        # @param cursor [Symbol] the field of the last item the next page
        #   starts after
        # @yieldparam item [Object]
        def each(fetch:, page_size: nil, cursor: :uuid, &)
          count = page_size.is_a?(Integer) && page_size.positive? ? page_size : DEFAULT_PAGE_SIZE
          from = nil
          loop do
            page = fetch.call(count, from)
            page.each(&)
            return if page.size < count

            last = page.last && page.last[cursor]
            # No usable cursor: stop rather than loop forever.
            return if last.nil? || last == from

            from = last
          end
        end
      end
    end
  end
end
