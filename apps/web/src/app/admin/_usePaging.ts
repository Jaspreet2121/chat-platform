"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { PageEnvelope, PageParams } from "@/lib/api";
import { DEFAULT_PAGE_SIZE, loadPageSize, savePageSize, type PageSize } from "@/lib/pager";

// The paging state every admin list shares: the page being asked for, the size the operator chose
// for THIS list, and the envelope the server last answered with. `params` is what goes on the
// request; `envelope` is what the pager renders. Only the two request fields drive a reload, so
// storing the envelope after a fetch cannot start another one.
export function usePaging(listKey: string) {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSizeState] = useState<PageSize>(DEFAULT_PAGE_SIZE);
  const [envelope, setEnvelope] = useState<PageEnvelope | null>(null);

  useEffect(() => {
    // Read AFTER mount, not as lazy initial state: the server render has no localStorage, so seeding
    // from it would make the first client render disagree with the server's and break hydration.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setPageSizeState(loadPageSize(listKey));
  }, [listKey]);

  const params = useMemo<PageParams>(() => ({ page, page_size: pageSize }), [page, pageSize]);

  const goTo = useCallback((next: number) => setPage(Math.max(1, Math.floor(next) || 1)), []);

  // A new size means a new list shape; page 1 is the only page whose meaning survives the change.
  const changePageSize = useCallback(
    (size: PageSize) => {
      savePageSize(listKey, size);
      setPageSizeState(size);
      setPage(1);
    },
    [listKey]
  );

  // What a FILTER change must do: page 7 of the old result set is nowhere in the new one.
  const reset = useCallback(() => setPage(1), []);

  return { page, pageSize, envelope, setEnvelope, params, goTo, changePageSize, reset };
}

export type Paging = ReturnType<typeof usePaging>;
