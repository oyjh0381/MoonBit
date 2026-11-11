///|
pub(all) struct BundlePublicationReceipt {
  publication : PublicationReceipt
  bundle_pin : @model.Digest
  verified_attachments : Int32
  listing_pages : Int32
}

///|
async fn PublishTransport::stage_bundle_attachments(
  self : PublishTransport,
  bundle : @registry.BundlePublicationPlan,
  root : @registry.PublishObject,
  discovery : @registry.DiscoveryLimits,
) -> Int32 {
  let origin = self.plan.origin()
  let repo = self.plan.repository()
  let root_url = origin.request_url(
    @registry.manifest_path(repo, root.digest.to_string()),
  )
  if !self.exists(root_url, root, true) {
    self.put(root_url, root, true)
  }
  for attachment in bundle.attachments() {
    let object = attachment.object
    let url = origin.request_url(
      @registry.manifest_path(repo, object.digest.to_string()),
    )
    if !self.exists(url, object, true) {
      self.put(url, object, true, subject=root.digest)
    }
    self.verify_manifest_readback(url, object)
  }
  let listing = @registry.ReferrerSession::new(
    origin,
    repo,
    root.digest,
    limits=discovery,
  )
  while listing.next_path() is Some(path) {
    let response = self.perform(() => {
      fetch_entity(
        origin.request_url(path),
        self.headers(true),
        listing.body_limit(),
        None,
        self.options.ca_file,
        self.options.proxy_origin,
      )
    })
    listing.accept(response.status, response.headers, response.body)
  }
  @registry.verify_bundle_advertisements(bundle, listing.advertisements())
  listing.pages()
}

///|
/// Stage the image root by digest, upload and read back its approved
/// attachments, then verify discovery before writing the final tag.
pub async fn publish_registry_bundle(
  bundle : @registry.BundlePublicationPlan,
  expected_bundle : @model.Digest,
  options~ : PublishOptions = PublishOptions::default(),
  discovery~ : @registry.DiscoveryLimits = @registry.DiscoveryLimits::default(),
  bearer_token? : String,
) -> BundlePublicationReceipt {
  if bundle.pin() != expected_bundle {
    raise @model.DigestMismatch("Registry bundle publication pin mismatch")
  }
  ignore(bundle.preflight(limits=options.limits, discovery~))
  let plan = bundle.publication()
  let transport = new_publish_transport(plan, options, bearer_token)
  let mut listing_pages = 0
  let publication = transport.run(plan.pin(), before_tag=root => {
    listing_pages = transport.stage_bundle_attachments(bundle, root, discovery)
  })
  {
    publication,
    bundle_pin: expected_bundle,
    verified_attachments: bundle.attachments().length(),
    listing_pages,
  }
}

///|
pub fn bundle_receipt_json(receipt : BundlePublicationReceipt) -> String {
  let result : Json = {
    "schema": "moonoci.registry-bundle-receipt.v1",
    "bundlePin": Json::string(receipt.bundle_pin.to_string()),
    "verifiedAttachments": Json::number(
      receipt.verified_attachments.to_double(),
    ),
    "listingPages": Json::number(receipt.listing_pages.to_double()),
    "publication": publication_receipt_value(receipt.publication),
  }
  result.stringify()
}
