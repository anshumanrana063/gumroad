import { router, usePage, useForm } from "@inertiajs/react";
import debounce from "lodash/debounce";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Follower } from "$app/data/followers";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { ExportSubscribersPopover } from "$app/components/Followers/ExportSubscribersPopover";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholder from "$assets/images/placeholders/followers.png";

const Layout = ({
  title,
  actions,
  children,
}: {
  title: string;
  actions?: React.ReactNode;
  children: React.ReactNode;
}) => {
  const loggedInUser = useLoggedInUser();

  return (
    <div>
      <PageHeader title={title} actions={actions}>
        <Tabs>
          <Tab href={Routes.published_emails_path()} isSelected={false}>
            Published
          </Tab>
          {loggedInUser?.policies.installment.create ? (
            <>
              <Tab href={Routes.scheduled_emails_path()} isSelected={false}>
                Scheduled
              </Tab>
              <Tab href={Routes.drafts_emails_path()} isSelected={false}>
                Drafts
              </Tab>
            </>
          ) : null}
          <Tab href={Routes.followers_path()} isSelected>
            Subscribers
          </Tab>
        </Tabs>
      </PageHeader>
      {children}
    </div>
  );
};

type Props = {
  followers: Follower[];
  total: number;
  current_page: number;
  per_page: number;
  search_query: string;
  has_more: boolean;
};

export default function FollowersPage() {
  const { followers, total, current_page, search_query, has_more } = cast<Props>(usePage().props);
  const userAgentInfo = useUserAgentInfo();

  const [selectedFollowerId, setSelectedFollowerId] = React.useState<string | null>(null);
  const [searchBoxOpen, setSearchBoxOpen] = React.useState(false);
  const [localSearchValue, setLocalSearchValue] = React.useState(search_query);
  const searchInputRef = React.useRef<HTMLInputElement | null>(null);
  const selectedFollower = followers.find((follower) => follower.id === selectedFollowerId);

  const searchForm = useForm({ email: search_query });
  const deleteForm = useForm({});

  React.useEffect(() => {
    if (searchBoxOpen) searchInputRef.current?.focus();
  }, [searchBoxOpen]);

  // Sync local search value with server state
  React.useEffect(() => {
    setLocalSearchValue(search_query);
  }, [search_query]);

  const navigateToSearch = (email: string) => {
    const params = new URLSearchParams(window.location.search);

    if (email.trim()) {
      params.set("email", email.trim());
    } else {
      params.delete("email");
    }

    // Reset to page 1 when searching
    params.delete("page");

    const url = new URL(window.location.href);
    url.search = params.toString();
    router.visit(url.toString(), {
      preserveState: true,
      preserveScroll: true,
      only: ["followers", "total", "current_page", "per_page", "search_query", "has_more", "total_pages"],
    });
  };

  // Pagination navigation function - uses visit with preserve options to avoid full reloads
  const navigateToPage = (page: number) => {
    const params = new URLSearchParams(window.location.search);
    params.set("page", page.toString());

    const url = new URL(window.location.href);
    url.search = params.toString();
    router.visit(url.toString(), {
      preserveState: true,
      preserveScroll: true,
      only: ["followers", "total", "current_page", "per_page", "search_query", "has_more", "total_pages"],
    });
  };

  // Debounced search handler
  const debouncedSearch = React.useCallback(
    debounce((query: string) => navigateToSearch(query), 300),
    [],
  );

  // Search input handler
  const handleSearchChange = (value: string) => {
    setLocalSearchValue(value);
    searchForm.setData("email", value);
    debouncedSearch(value);
  };

  const handleDeleteFollower = (followerId: string) => {
    setSelectedFollowerId(null);
    deleteForm.delete(Routes.follower_path({ id: followerId }), {
      preserveScroll: true,
      onSuccess: () => showAlert("Follower removed!", "success"),
      onError: () => showAlert("Failed to remove follower.", "error"),
    });
  };

  const currentSeller = useCurrentSeller();

  return (
    <Layout
      title="Subscribers"
      actions={
        <>
          {followers.length > 0 || localSearchValue.length > 0 || searchBoxOpen ? (
            <Popover
              open={searchBoxOpen}
              onToggle={setSearchBoxOpen}
              aria-label="Search"
              trigger={
                <WithTooltip tip="Search" position="bottom">
                  <div className="button">
                    <Icon name="solid-search" />
                  </div>
                </WithTooltip>
              }
            >
              <input
                ref={searchInputRef}
                value={localSearchValue}
                autoFocus
                type="text"
                placeholder="Search followers"
                onChange={(evt) => handleSearchChange(evt.target.value)}
              />
            </Popover>
          ) : null}
          <Popover
            aria-label="Export"
            trigger={
              <WithTooltip tip="Export" position="bottom">
                <Button aria-label="Export">
                  <Icon aria-label="Download" name="download" />
                </Button>
              </WithTooltip>
            }
          >
            {(close) => <ExportSubscribersPopover closePopover={close} />}
          </Popover>

          {currentSeller ? (
            <CopyToClipboard
              tooltipPosition="bottom"
              text={Routes.custom_domain_subscribe_url({ host: currentSeller.subdomain })}
            >
              <Button>
                <Icon name="link" />
                Share subscribe page
              </Button>
            </CopyToClipboard>
          ) : null}
        </>
      }
    >
      <div className="space-y-4 p-4 md:p-8">
        {followers.length > 0 ? (
          <div>
            <Table>
              <TableCaption>All subscribers ({total.toLocaleString(userAgentInfo.locale)})</TableCaption>
              <TableHeader>
                <TableRow>
                  <TableHead>Email</TableHead>
                  <TableHead>Date Added</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {followers.map((follower) => (
                  <TableRow
                    key={follower.id}
                    onClick={() => setSelectedFollowerId(follower.id === selectedFollowerId ? null : follower.id)}
                    selected={selectedFollowerId === follower.id}
                  >
                    <TableCell>{follower.email}</TableCell>
                    <TableCell>{follower.formatted_confirmed_on}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            {has_more ? (
              <Button
                color="primary"
                onClick={() => navigateToPage(current_page + 1)}
                disabled={searchForm.processing}
                className="mt-6"
              >
                Load more
              </Button>
            ) : null}
            {selectedFollower ? (
              <Sheet
                open
                onOpenChange={() => setSelectedFollowerId(null)}
                className={selectedFollower.can_update ? "" : "js-team-member-read-only"}
              >
                <SheetHeader>Details</SheetHeader>
                <div className="stack">
                  <div>
                    <div>
                      <h4>Email</h4>
                      <div>{selectedFollower.email}</div>
                      <Button
                        color="danger"
                        onClick={() => handleDeleteFollower(selectedFollower.id)}
                        disabled={deleteForm.processing}
                        className="mt-2"
                      >
                        {deleteForm.processing ? "Removing..." : "Remove follower"}
                      </Button>
                    </div>
                  </div>
                </div>
              </Sheet>
            ) : null}
          </div>
        ) : (
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            {search_query.length === 0 ? (
              <>
                <h2>Manage all of your followers in one place.</h2>
                Interacting with and serving your audience is an important part of running your business.
                {currentSeller ? (
                  <CopyToClipboard
                    tooltipPosition="bottom"
                    text={Routes.custom_domain_subscribe_url({ host: currentSeller.subdomain })}
                  >
                    <Button color="accent">Share subscribe page</Button>
                  </CopyToClipboard>
                ) : null}
                <p>
                  or{" "}
                  <a href="/help/article/170-audience" target="_blank" rel="noreferrer">
                    learn more about the audience dashboard
                  </a>
                </p>
              </>
            ) : (
              <h2>No followers found</h2>
            )}
          </Placeholder>
        )}
      </div>
    </Layout>
  );
}
